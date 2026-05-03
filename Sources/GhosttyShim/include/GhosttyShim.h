#ifndef GHOSTTY_SHIM_H
#define GHOSTTY_SHIM_H

#include <stdbool.h>
#include <stdint.h>

#include "ghostty.h"

#ifdef __cplusplus
extern "C" {
#endif

typedef struct gsde_ghostty_host gsde_ghostty_host_t;

const char *gsde_ghostty_status(void);
gsde_ghostty_host_t *gsde_ghostty_host_create(void *nsview, double scale_factor, uint32_t width_px, uint32_t height_px);
void gsde_ghostty_host_destroy(gsde_ghostty_host_t *host);
void gsde_ghostty_host_resize(gsde_ghostty_host_t *host, double scale_factor, uint32_t width_px, uint32_t height_px);
void gsde_ghostty_host_focus(gsde_ghostty_host_t *host, bool focused);
void gsde_ghostty_host_tick(gsde_ghostty_host_t *host);
void gsde_ghostty_host_draw(gsde_ghostty_host_t *host);
void gsde_ghostty_host_text(gsde_ghostty_host_t *host, const char *text, uintptr_t len);
bool gsde_ghostty_host_key(gsde_ghostty_host_t *host, ghostty_input_key_s event);
bool gsde_ghostty_host_is_loaded(gsde_ghostty_host_t *host);

#ifdef __cplusplus
}
#endif

#endif
