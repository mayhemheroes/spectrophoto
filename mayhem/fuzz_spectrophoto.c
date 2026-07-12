/* In-process libFuzzer harness for spectrophoto.
 *
 * The upstream program is a raw-file-input CLI (`spectrophoto in.img out.pcm <dur>`) that
 * decodes an image with stb_image and turns it into a raw-PCM "spectrogram". A file-input
 * Mayhem target over it is unfuzzable in practice (it must write a multi-MB .pcm file to a
 * scratch path on every exec and re-exec per input), so we drive the SAME code path in
 * process: stbi_load_from_memory() over the fuzz input, then the project's own
 * get_pixel_intensity()/get_point_index()/column_to_PCM() pipeline (compiled straight from
 * spectrophoto.c, with its main() renamed away — see build.sh). stb_image's decoders are the
 * real bug surface; the PCM pipeline is exercised for parity with the original target.
 *
 * Dimensions/samples are capped so a single input stays within a bounded time/memory budget
 * (the CLI would OOM/hang on adversarial dimensions); this only bounds the harness, the decode
 * and the arithmetic run exactly as upstream wrote them.
 */
#include <stdint.h>
#include <stddef.h>
#include <stdlib.h>
#include <math.h>

#ifndef M_PI
#define M_PI 3.14159265358979323846
#endif

#include "stb_image.h"

#define SAMPLE_RATE 48000

/* defined in spectrophoto.c (compiled with -Dmain=spectrophoto_orig_main) */
void  column_to_PCM(float *buf, float *column, int nb_samples, int height, float **sin_lut);
int   get_point_index(int i, int j, int x, int n);
float get_pixel_intensity(unsigned char *img, int n);

int LLVMFuzzerTestOneInput(const uint8_t *data, size_t size)
{
  int x = 0, y = 0, n = 0;
  unsigned char *img = stbi_load_from_memory(data, (int)size, &x, &y, &n, 1);
  if (!img)
    return 0;

  /* keep the harness bounded (upstream CLI has no such guard) */
  if (x <= 0 || y <= 0 || y > 4096 || (long)x * (long)y > (1L << 16)) {
    stbi_image_free(img);
    return 0;
  }

  int duration = 1;
  int nb_samples = (duration * SAMPLE_RATE) / x;
  if (nb_samples <= 0) {
    stbi_image_free(img);
    return 0;
  }
  if (nb_samples > 128)
    nb_samples = 128;

  float *column  = malloc(sizeof(float) * (size_t)y);
  float *buf     = malloc(sizeof(float) * (size_t)nb_samples);
  float **sin_lut = malloc(sizeof(float *) * (size_t)y);
  if (!column || !buf || !sin_lut) {
    free(column); free(buf); free(sin_lut);
    stbi_image_free(img);
    return 0;
  }

  int allocated = 0;
  int ok = 1;
  for (; allocated < y; allocated++) {
    sin_lut[allocated] = malloc(sizeof(float) * (size_t)nb_samples);
    if (!sin_lut[allocated]) { ok = 0; break; }
  }

  if (ok) {
    float nyquist = (float)SAMPLE_RATE / 2;
    float hz_step = nyquist / y;
    for (int i = 0; i < y; i++) {
      for (int j = 0; j < nb_samples; j++) {
        float freq = nyquist - (hz_step * i);
        float env = sin(2 * M_PI * ((float)j / nb_samples));
        sin_lut[i][j] = env * sin(2 * M_PI * freq * ((float)j / SAMPLE_RATE));
      }
    }
    for (int i = 0; i < x; i++) {
      for (int j = 0; j < y; j++) {
        int index = get_point_index(i, j, x, 1);
        column[j] = get_pixel_intensity(&img[index], 1);
      }
      column_to_PCM(buf, column, nb_samples, y, sin_lut);
    }
  }

  for (int i = 0; i < allocated; i++)
    free(sin_lut[i]);
  free(sin_lut);
  free(buf);
  free(column);
  stbi_image_free(img);
  return 0;
}
