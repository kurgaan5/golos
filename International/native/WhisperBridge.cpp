#include "WhisperBridge.h"
#include "whisper.h"
#include "ggml-backend.h"
#include <mutex>
#include <string>
#include <cstdlib>
#include <cstring>
#include <thread>
#include <vector>
#include <sstream>
#include <cmath>
#include <algorithm>

struct GolosContext {
    whisper_context *asr;
    whisper_vad_context *vad;
    std::string vocabulary;
    std::vector<whisper_token> prompt;
    int vocabulary_count = 0;
    int rejection = 0;
    float speech_seconds = 0;
    float mean_logprob = 0;
};

static int set_vocabulary(GolosContext *state, const char *vocabulary) {
    const std::string text = vocabulary ? vocabulary : "";
    if (state->vocabulary == text) return state->vocabulary_count;
    state->vocabulary = text;
    state->prompt.clear();
    state->vocabulary_count = 0;
    // Whisper uses at most half its text context for an initial prompt, plus SOT_PREV.
    // Fit complete entries explicitly instead of silently dropping the priority prefix.
    const int budget = whisper_n_text_ctx(state->asr) / 2 - 1;
    std::istringstream lines(text);
    std::string term;
    while (std::getline(lines, term)) {
        if (term.empty()) continue;
        const std::string entry = (state->prompt.empty() ? " " : ", ") + term;
        std::vector<whisper_token> tokens(entry.size() + 1);
        const int count = whisper_tokenize(state->asr, entry.c_str(), tokens.data(), tokens.size());
        if (count <= 0 || state->prompt.size() + count > budget) break;
        state->prompt.insert(state->prompt.end(), tokens.begin(), tokens.begin() + count);
        ++state->vocabulary_count;
    }
    return state->vocabulary_count;
}

extern "C" {
void * golos_activity_create(const char *path) {
    auto params = whisper_vad_default_context_params();
    params.n_threads = 2; params.use_gpu = false;
    return whisper_vad_init_from_file_with_params(path, params);
}
int golos_activity_detect(void *context, const float *samples, int count) {
    auto *vad = static_cast<whisper_vad_context *>(context);
    if (!vad || !samples) return -1;
    if (count < 1600) return 0;
    if (!whisper_vad_detect_speech(vad, samples, count)) return -1;
    int speech_frames = 0;
    const int n = whisper_vad_n_probs(vad);
    const auto *probs = whisper_vad_probs(vad);
    for (int i = 0; i < n; ++i) if (probs[i] >= 0.5f) ++speech_frames;
    return speech_frames >= 3 ? 1 : 0;
}
void golos_activity_destroy(void *context) {
    if (context) whisper_vad_free(static_cast<whisper_vad_context *>(context));
}
void * golos_create(const char *path) {
    static std::once_flag backends;
    std::call_once(backends, [] { ggml_backend_load_all(); });
    auto params = whisper_context_default_params();
    params.use_gpu = false;
    auto *ctx = whisper_init_from_file_with_params(path, params);
    if (!ctx) {
        params.use_gpu = false;
        ctx = whisper_init_from_file_with_params(path, params);
    }
    if (!ctx) return nullptr;
    std::string model_path(path);
    const auto split = model_path.find_last_of("/\\");
    const auto vad_path = model_path.substr(0, split + 1) + "ggml-silero-v5.1.2.bin";
    auto vad_params = whisper_vad_default_context_params();
    vad_params.n_threads = 2;
    vad_params.use_gpu = false;
    auto *vad = whisper_vad_init_from_file_with_params(vad_path.c_str(), vad_params);
    if (!vad) { whisper_free(ctx); return nullptr; }
    return new GolosContext{ctx, vad};
}
int golos_vocabulary_count(void *context, const char *vocabulary) {
    auto *state = static_cast<GolosContext *>(context);
    return state ? set_vocabulary(state, vocabulary) : 0;
}
const char * golos_detect_language(void *context, const float *samples, int count, const char *allowed_languages, float *confidence, float *runner_up) {
    if (confidence) *confidence = 0;
    if (runner_up) *runner_up = 0;
    auto *state = static_cast<GolosContext *>(context);
    if (!state || !samples || count < 48000 || !allowed_languages) return nullptr;
    const int threads = std::min(6u, std::max(2u, std::thread::hardware_concurrency() / 2));
    if (whisper_pcm_to_mel(state->asr, samples, count, threads) != 0) return nullptr;
    std::vector<float> probabilities(whisper_lang_max_id() + 1, 0.0f);
    if (whisper_lang_auto_detect(state->asr, 0, threads, probabilities.data()) < 0) return nullptr;
    std::istringstream input(allowed_languages);
    std::string language;
    int best = -1;
    float first = 0, second = 0;
    while (std::getline(input, language, ',')) {
        const int id = whisper_lang_id(language.c_str());
        if (id < 0 || id >= (int)probabilities.size()) continue;
        const float p = probabilities[id];
        if (p > first) { second = first; first = p; best = id; }
        else if (p > second) { second = p; }
    }
    if (confidence) *confidence = first;
    if (runner_up) *runner_up = second;
    return best >= 0 ? whisper_lang_str(best) : nullptr;
}
char * golos_transcribe(void *context, const float *samples, int count, const char *language, int final_pass, const char *vocabulary) {
    auto *state = static_cast<GolosContext *>(context);
    if (!state || count < 1600) return _strdup("");
    state->rejection = 0; state->speech_seconds = 0; state->mean_logprob = 0;
    if (!whisper_vad_detect_speech(state->vad, samples, count)) return nullptr;
    int speech_frames = 0;
    const int n_probs = whisper_vad_n_probs(state->vad);
    const auto *probs = whisper_vad_probs(state->vad);
    for (int i = 0; i < n_probs; ++i) if (probs[i] >= 0.5f) ++speech_frames;
    state->speech_seconds = speech_frames * 512.0f / 16000.0f;
    // A click/noise burst can cross the energy threshold without containing a
    // usable utterance. Do not ask Whisper to complete it from the vocabulary.
    if (speech_frames < (final_pass ? 5 : 8)) { state->rejection = 1; return _strdup(""); }
    auto *ctx = state->asr;
    const int threads = std::min(6u, std::max(2u, std::thread::hardware_concurrency() / 2));
    std::string selected = language ? language : "auto";
    if (whisper_lang_id(selected.c_str()) < 0) return nullptr;
    auto params = whisper_full_default_params(final_pass ? WHISPER_SAMPLING_BEAM_SEARCH : WHISPER_SAMPLING_GREEDY);
    params.beam_search.beam_size = 3;
    params.greedy.best_of = 1;
    params.language = selected.c_str();
    params.translate = false;
    params.no_context = true;
    params.no_timestamps = true;
    params.print_special = false;
    params.print_progress = false;
    params.print_realtime = false;
    params.print_timestamps = false;
    params.suppress_blank = true;
    params.suppress_nst = true;
    params.temperature = 0.0f;
    params.temperature_inc = 0.0f;
    params.n_threads = threads;
    params.max_tokens = std::max(24, std::min(384, int(std::ceil(state->speech_seconds * 32)) + 16));
    set_vocabulary(state, vocabulary);
    if (!state->prompt.empty()) {
        params.prompt_tokens = state->prompt.data();
        params.prompt_n_tokens = state->prompt.size();
    }
    if (whisper_full(ctx, params, samples, count) != 0) return nullptr;
    std::string result;
    double logprob = 0;
    int text_tokens = 0;
    for (int i = 0; i < whisper_full_n_segments(ctx); ++i) {
        if (whisper_full_get_segment_no_speech_prob(ctx, i) > 0.5f) continue;
        int segment_tokens = 0;
        for (int j = 0; j < whisper_full_n_tokens(ctx, i); ++j) {
            const auto token = whisper_full_get_token_data(ctx, i, j);
            if (token.id >= whisper_token_eot(ctx)) continue;
            logprob += std::log(std::max(token.p, 1e-8f));
            ++text_tokens; ++segment_tokens;
        }
        if (segment_tokens >= params.max_tokens) { state->rejection = 3; return _strdup(""); }
        result += whisper_full_get_segment_text(ctx, i);
    }
    state->mean_logprob = text_tokens ? logprob / text_tokens : 0;
    if (text_tokens && state->mean_logprob < -1.1f) { state->rejection = 2; return _strdup(""); }
    return _strdup(result.c_str());
}
int golos_last_rejection(void *context) { return static_cast<GolosContext *>(context)->rejection; }
float golos_last_speech_seconds(void *context) { return static_cast<GolosContext *>(context)->speech_seconds; }
float golos_last_logprob(void *context) { return static_cast<GolosContext *>(context)->mean_logprob; }
const char * golos_detected_language(void *context) {
    const int id = whisper_full_lang_id(static_cast<GolosContext *>(context)->asr);
    return id >= 0 ? whisper_lang_str(id) : "auto";
}
void golos_destroy(void *context) {
    if (auto *state = static_cast<GolosContext *>(context)) {
        whisper_vad_free(state->vad); whisper_free(state->asr); delete state;
    }
}
void golos_free_text(char *text) { free(text); }
}
