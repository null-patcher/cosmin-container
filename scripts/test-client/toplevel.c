// SPDX-License-Identifier: GPL-3.0-only
//
// Minimal resizable xdg-shell client used by scripts/functional-zoom.sh to
// exercise the compositor's tiling code. It creates one toplevel, resizes its
// shm buffer to whatever the compositor asks for, and prints every configure
// as "CONFIGURE <w> <h>" so the test can assert geometry changes.
//
// Build (inside the dev container, see scripts/functional-zoom.sh):
//   wayland-scanner client-header  $XDG_XML xdg-shell-client-protocol.h
//   wayland-scanner private-code   $XDG_XML xdg-shell-protocol.c
//   cc toplevel.c xdg-shell-protocol.c -lwayland-client -o toplevel

#define _GNU_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <sys/mman.h>
#include <fcntl.h>
#include <errno.h>
#include <wayland-client.h>
#include "xdg-shell-client-protocol.h"

struct state {
    struct wl_display *display;
    struct wl_registry *registry;
    struct wl_compositor *compositor;
    struct wl_shm *shm;
    struct xdg_wm_base *wm_base;
    struct wl_surface *surface;
    struct xdg_surface *xdg_surface;
    struct xdg_toplevel *toplevel;
    struct wl_buffer *buffer;
    void *pool_data;
    size_t pool_size;
    int width, height;
    int pending_w, pending_h;
    uint32_t color;
    int configured;
};

static void buffer_release(void *data, struct wl_buffer *buffer) {
    (void)data; (void)buffer;
}
static const struct wl_buffer_listener buffer_listener = { buffer_release };

static int create_pool_file(size_t size) {
    char name[] = "/tmp/wl-shm-XXXXXX";
    int fd = mkstemp(name);
    if (fd < 0) return -1;
    unlink(name);
    if (ftruncate(fd, (off_t)size) < 0) { close(fd); return -1; }
    return fd;
}

static void create_buffer(struct state *s, int w, int h) {
    int stride = w * 4;
    size_t size = (size_t)stride * h;
    if (s->buffer) { wl_buffer_destroy(s->buffer); s->buffer = NULL; }
    if (s->pool_data) { munmap(s->pool_data, s->pool_size); s->pool_data = NULL; }
    int fd = create_pool_file(size);
    s->pool_data = mmap(NULL, size, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
    s->pool_size = size;
    uint32_t *p = s->pool_data;
    for (size_t i = 0; i < size / 4; i++) p[i] = s->color;
    struct wl_shm_pool *pool = wl_shm_create_pool(s->shm, fd, (int)size);
    s->buffer = wl_shm_pool_create_buffer(pool, 0, w, h, stride, WL_SHM_FORMAT_XRGB8888);
    wl_buffer_add_listener(s->buffer, &buffer_listener, s);
    wl_shm_pool_destroy(pool);
    close(fd);
    s->width = w; s->height = h;
}

static void xdg_surface_configure(void *data, struct xdg_surface *xs, uint32_t serial) {
    struct state *s = data;
    if (s->pending_w <= 0 || s->pending_h <= 0) { s->pending_w = 400; s->pending_h = 300; }
    create_buffer(s, s->pending_w, s->pending_h);
    wl_surface_attach(s->surface, s->buffer, 0, 0);
    wl_surface_damage_buffer(s->surface, 0, 0, s->width, s->height);
    xdg_surface_ack_configure(xs, serial);
    wl_surface_commit(s->surface);
    s->configured = 1;
    printf("CONFIGURE %d %d\n", s->width, s->height);
    fflush(stdout);
}
static const struct xdg_surface_listener xdg_surface_listener = { xdg_surface_configure };

static void xdg_toplevel_configure(void *data, struct xdg_toplevel *tl, int32_t w, int32_t h, struct wl_array *states) {
    (void)tl; (void)states;
    struct state *s = data;
    if (w > 0) s->pending_w = w;
    if (h > 0) s->pending_h = h;
}
static void xdg_toplevel_close(void *data, struct xdg_toplevel *tl) {
    (void)tl; (void)data; exit(0);
}
static void xdg_toplevel_configure_bounds(void *data, struct xdg_toplevel *tl, int32_t w, int32_t h) {
    (void)data; (void)tl; (void)w; (void)h;
}
static void xdg_toplevel_wm_capabilities(void *data, struct xdg_toplevel *tl, struct wl_array *caps) {
    (void)data; (void)tl; (void)caps;
}
static const struct xdg_toplevel_listener xdg_toplevel_listener = {
    xdg_toplevel_configure, xdg_toplevel_close, xdg_toplevel_configure_bounds, xdg_toplevel_wm_capabilities,
};

static void wm_base_ping(void *data, struct xdg_wm_base *wm, uint32_t serial) {
    (void)data; xdg_wm_base_pong(wm, serial);
}
static const struct xdg_wm_base_listener wm_base_listener = { wm_base_ping };

static void registry_global(void *data, struct wl_registry *reg, uint32_t name, const char *iface, uint32_t version) {
    struct state *s = data;
    if (strcmp(iface, wl_compositor_interface.name) == 0) {
        s->compositor = wl_registry_bind(reg, name, &wl_compositor_interface, version < 4 ? version : 4);
    } else if (strcmp(iface, wl_shm_interface.name) == 0) {
        s->shm = wl_registry_bind(reg, name, &wl_shm_interface, 1);
    } else if (strcmp(iface, xdg_wm_base_interface.name) == 0) {
        s->wm_base = wl_registry_bind(reg, name, &xdg_wm_base_interface, version < 2 ? version : 2);
        xdg_wm_base_add_listener(s->wm_base, &wm_base_listener, s);
    }
}
static void registry_global_remove(void *data, struct wl_registry *reg, uint32_t name) {
    (void)data; (void)reg; (void)name;
}
static const struct wl_registry_listener registry_listener = { registry_global, registry_global_remove };

int main(void) {
    struct state s; memset(&s, 0, sizeof(s));
    const char *c = getenv("TEST_COLOR");
    s.color = c ? (uint32_t)strtoul(c, NULL, 0) : 0xff3060a0;
    s.pending_w = 400; s.pending_h = 300;

    s.display = wl_display_connect(NULL);
    if (!s.display) { fprintf(stderr, "wl_display_connect failed\n"); return 1; }
    s.registry = wl_display_get_registry(s.display);
    wl_registry_add_listener(s.registry, &registry_listener, &s);
    wl_display_roundtrip(s.display);

    s.surface = wl_compositor_create_surface(s.compositor);
    s.xdg_surface = xdg_wm_base_get_xdg_surface(s.wm_base, s.surface);
    xdg_surface_add_listener(s.xdg_surface, &xdg_surface_listener, &s);
    s.toplevel = xdg_surface_get_toplevel(s.xdg_surface);
    xdg_toplevel_add_listener(s.toplevel, &xdg_toplevel_listener, &s);
    const char *title = getenv("TEST_TITLE");
    xdg_toplevel_set_title(s.toplevel, title ? title : "toplevel-test");
    xdg_toplevel_set_app_id(s.toplevel, "cosmic-container.test");
    wl_surface_commit(s.surface);

    while (wl_display_dispatch(s.display) != -1) { }
    return 0;
}
