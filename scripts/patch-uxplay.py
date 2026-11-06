#!/usr/bin/env python3
"""Adds machine-readable "@@PT ..." event lines to UxPlay's stdout so the Espelho app can
follow the connection state. Idempotent: running it twice changes nothing."""
import sys, pathlib

path = pathlib.Path(sys.argv[1] if len(sys.argv) > 1 else "vendor/UxPlay/uxplay.cpp")
src = path.read_text()
WATCHDOG = '''
/* Espelho: if the app goes away (crash, force quit), the receiver goes away with it. */
#include <pthread.h>
#include <unistd.h>
static void *pt_watch_parent_loop(void *) {
    pid_t parent = getppid();
    for (;;) {
        sleep(1);
        if (getppid() != parent) _exit(0);
    }
    return NULL;
}
__attribute__((constructor)) static void pt_watch_parent(void) {
    pthread_t thread;
    if (pthread_create(&thread, NULL, pt_watch_parent_loop, NULL) == 0) pthread_detach(thread);
}
'''

def add_watchdog(src):
    if "pt_watch_parent" in src:
        return src
    anchor = '#include "renderers/mux_renderer.h"\n'
    if src.count(anchor) != 1:
        sys.exit("patch-uxplay: ponto do watchdog não encontrado")
    return src.replace(anchor, anchor + WATCHDOG)

if "pt_event(" in src:
    new = add_watchdog(src)
    if new != src:
        path.write_text(new)
        print("uxplay.cpp: watchdog adicionado")
    else:
        print("uxplay.cpp já tem o patch")
    sys.exit(0)

HELPER = '''
/* Espelho: one line per state change on stdout, parsed by the macOS app. */
static void pt_event(const char *fmt, ...) {
    va_list ap;
    va_start(ap, fmt);
    fputs("@@PT ", stdout);
    vfprintf(stdout, fmt, ap);
    fputc('\\n', stdout);
    fflush(stdout);
    va_end(ap);
}
'''

edits = [
    ('#include "renderers/mux_renderer.h"\n',
     '#include "renderers/mux_renderer.h"\n' + HELPER),
    ('    LOGD("register_dnssd: advertised AirPlay service',
     '    pt_event("ready");\n    LOGD("register_dnssd: advertised AirPlay service'),
    ('    open_connections++;\n',
     '    open_connections++;\n    pt_event("conns %d", open_connections);\n'),
    ('    open_connections--;\n',
     '    open_connections--;\n    pt_event("conns %d", open_connections);\n'),
    ('    LOGI("connection request from %s (%s) with deviceID = %s\\n", name, model, deviceid);\n',
     '    LOGI("connection request from %s (%s) with deviceID = %s\\n", name, model, deviceid);\n'
     '    pt_event("client %s\\t%s", model ? model : "", name ? name : "");\n'),
    ('        LOGD("video_reset: type = NoHold");\n',
     '        LOGD("video_reset: type = NoHold");\n        pt_event("stop");\n'),
    ('        LOGD("video_reset: type = RTP_Shutdown");',
     '        LOGD("video_reset: type = RTP_Shutdown");\n        pt_event("stop");'),
    ('    bool video_is_h265 = (codec == VIDEO_CODEC_H265);\n',
     '    bool video_is_h265 = (codec == VIDEO_CODEC_H265);\n'
     '    pt_event("video %d %d %d", video_is_h265 ? 265 : 264, (int) width, (int) height);\n'),
    ('extern "C" void conn_reset (void *cls, int reason) {\n',
     'extern "C" void conn_reset (void *cls, int reason) {\n    pt_event("lost %d", reason);\n'),
    ('    char *image = create_pin_display(pin, margin, spacing);\n',
     '    pt_event("pin %s", pin);\n    char *image = create_pin_display(pin, margin, spacing);\n'),
]

for old, new in edits:
    count = src.count(old)
    if count != 1:
        sys.exit(f"patch-uxplay: trecho encontrado {count}x (esperado 1): {old[:60]!r}")
    src = src.replace(old, new)

path.write_text(add_watchdog(src))
print("uxplay.cpp: patch aplicado")
