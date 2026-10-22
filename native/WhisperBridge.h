#include <stdint.h>
#ifdef _WIN32
#define GOLOS_API __declspec(dllexport)
#else
#define GOLOS_API
#endif
#ifdef __cplusplus
extern "C" {
#endif
GOLOS_API void *golos_create(const char *model_path);
GOLOS_API int golos_vocabulary_count(void *context, const char *vocabulary);
GOLOS_API char *golos_transcribe(void *context, const float *samples, int count, const char *language, int final_pass, const char *vocabulary);
GOLOS_API const char *golos_detected_language(void *context);
GOLOS_API void golos_destroy(void *context);
GOLOS_API void golos_free_text(char *text);
#ifdef __cplusplus
}
#endif
