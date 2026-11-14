#include <stdint.h>
#include <CommonCrypto/CommonKeyDerivation.h>
#ifdef __cplusplus
extern "C" {
#endif
void *golos_activity_create(const char *model_path);
int golos_activity_detect(void *context, const float *samples, int count);
void golos_activity_destroy(void *context);
void * golos_create(const char *model_path);
int golos_vocabulary_count(void *context, const char *vocabulary);
const char * golos_detect_language(void *context, const float *samples, int count, const char *allowed_languages, float *confidence, float *runner_up);
char * golos_transcribe(void *context, const float *samples, int count, const char *language, int final_pass, const char *vocabulary);
const char * golos_detected_language(void *context);
int golos_last_rejection(void *context);
float golos_last_speech_seconds(void *context);
float golos_last_logprob(void *context);
void golos_destroy(void *context);
void golos_free_text(char *text);
#ifdef __cplusplus
}
#endif
