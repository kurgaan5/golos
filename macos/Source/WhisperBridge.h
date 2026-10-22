#include <stdint.h>
#include <CommonCrypto/CommonKeyDerivation.h>
#ifdef __cplusplus
extern "C" {
#endif
void * golos_create(const char *model_path);
int golos_vocabulary_count(void *context, const char *vocabulary);
char * golos_transcribe(void *context, const float *samples, int count, const char *language, int final_pass, const char *vocabulary);
const char * golos_detected_language(void *context);
void golos_destroy(void *context);
void golos_free_text(char *text);
#ifdef __cplusplus
}
#endif
