#ifndef INPUTDECK_BRIDGE_H
#define INPUTDECK_BRIDGE_H

typedef struct {
    float x;
    float y;
    float size;
} IDFinger;

// Uses Apple's private MultitouchSupport framework, if available.
int id_trackpad_start(void);
int id_trackpad_copy(IDFinger *output, int max_points);
void id_trackpad_stop(void);

// Localhost-only HTTP + Server-Sent Events server for OBS Browser Source.
int id_server_start(const char *html_path, int port);
void id_server_publish(const char *json);
void id_server_stop(void);

#endif
