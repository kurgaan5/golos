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

struct GolosContext {
    whisper_context *asr;
    whisper_vad_context *vad;
    std::string vocabulary;
    std::vector<whisper_token> prompt;
    int vocabulary_count = 0;
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
char * golos_transcribe(void *context, const float *samples, int count, const char *language, int final_pass, const char *vocabulary) {
    auto *state = static_cast<GolosContext *>(context);
    if (!state || count < 1600) return _strdup("");
    if (!whisper_vad_detect_speech(state->vad, samples, count)) return nullptr;
    int speech_frames = 0;
    const int n_probs = whisper_vad_n_probs(state->vad);
    const auto *probs = whisper_vad_probs(state->vad);
    for (int i = 0; i < n_probs; ++i) if (probs[i] >= 0.5f) ++speech_frames;
    if (speech_frames < 3) return _strdup("");
    auto *ctx = state->asr;
    const int threads = std::min(6u, std::max(2u, std::thread::hardware_concurrency() / 2));
    std::string selected = language ? language : "auto";
    if (selected != "ru" && selected != "en") {
        selected = "ru";
        if (whisper_pcm_to_mel(ctx, samples, count, threads) == 0) {
            std::vector<float> probabilities(whisper_lang_max_id() + 1, 0.0f);
            if (whisper_lang_auto_detect(ctx, 0, threads, probabilities.data()) >= 0) {
                const float english = probabilities[whisper_lang_id("en")];
                const float russian = probabilities[whisper_lang_id("ru")];
                if (english > 0.4f && english > russian * 1.35f) selected = "en";
            }
        }
    }
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
    set_vocabulary(state, vocabulary);
    if (!state->prompt.empty()) {
        params.prompt_tokens = state->prompt.data();
        params.prompt_n_tokens = state->prompt.size();
    }
    if (whisper_full(ctx, params, samples, count) != 0) return nullptr;
    std::string result;
    for (int i = 0; i < whisper_full_n_segments(ctx); ++i) {
        if (whisper_full_get_segment_no_speech_prob(ctx, i) > 0.5f) continue;
        result += whisper_full_get_segment_text(ctx, i);
    }
    return _strdup(result.c_str());
}
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
