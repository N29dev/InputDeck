#include "Bridge.h"
#include <arpa/inet.h>
#include <dlfcn.h>
#include <errno.h>
#include <fcntl.h>
#include <math.h>
#include <netinet/in.h>
#include <pthread.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <strings.h>
#include <sys/socket.h>
#include <sys/types.h>
#include <sys/time.h>
#include <unistd.h>

// Layout used by macOS MultitouchSupport contact callbacks. This API is private
// and may change between macOS releases; we intentionally fail gracefully.
typedef struct { float x, y; } MTPoint;
typedef struct { MTPoint pos, vel; } MTReadout;
typedef struct {
    int frame;
    double timestamp;
    int identifier;
    int state;
    int finger_id;
    int hand_id;
    MTReadout normalized;
    float size;
    int zero1;
    float angle;
    float major_axis;
    float minor_axis;
    MTReadout absolute;
    int zero2[2];
    float density;
} MTTouch;

typedef void *(*CreateDefaultFn)(void);
typedef void (*RegisterFn)(void *, int (*)(int, MTTouch *, int, double, int));
typedef void (*StartFn)(void *, int);
typedef void (*StopFn)(void *);
typedef void (*ReleaseFn)(void *);

static pthread_mutex_t mt_lock = PTHREAD_MUTEX_INITIALIZER;
static IDFinger mt_fingers[16];
static int mt_count = 0;
static void *mt_library = NULL;
static void *mt_device = NULL;
static StopFn mt_stop_fn = NULL;
static ReleaseFn mt_release_fn = NULL;

static int mt_callback(int device, MTTouch *touches, int n, double timestamp, int frame) {
    (void)device; (void)timestamp; (void)frame;
    IDFinger next[16];
    int count = 0;
    if (touches) {
        for (int i = 0; i < n && count < 16; i++) {
            float x = touches[i].normalized.pos.x;
            float y = touches[i].normalized.pos.y;
            if (!isfinite(x) || !isfinite(y) || x < -0.1f || x > 1.1f || y < -0.1f || y > 1.1f) continue;
            // The contact framework also reports brief lift/hover states.
            if (touches[i].state <= 0) continue;
            next[count++] = (IDFinger){.x = fminf(1, fmaxf(0, x)),
                                       .y = fminf(1, fmaxf(0, y)),
                                       .size = touches[i].size,
                                       .identifier = touches[i].identifier};
        }
    }
    pthread_mutex_lock(&mt_lock);
    memcpy(mt_fingers, next, (size_t)count * sizeof(IDFinger));
    mt_count = count;
    pthread_mutex_unlock(&mt_lock);
    return 0;
}

int id_trackpad_start(void) {
    if (mt_device) return 1;
    mt_library = dlopen("/System/Library/PrivateFrameworks/MultitouchSupport.framework/MultitouchSupport", RTLD_NOW);
    if (!mt_library) return 0;
    CreateDefaultFn create = (CreateDefaultFn)dlsym(mt_library, "MTDeviceCreateDefault");
    RegisterFn reg = (RegisterFn)dlsym(mt_library, "MTRegisterContactFrameCallback");
    StartFn start = (StartFn)dlsym(mt_library, "MTDeviceStart");
    mt_stop_fn = (StopFn)dlsym(mt_library, "MTDeviceStop");
    mt_release_fn = (ReleaseFn)dlsym(mt_library, "MTDeviceRelease");
    if (!create || !reg || !start) {
        dlclose(mt_library); mt_library = NULL;
        return 0;
    }
    mt_device = create();
    if (!mt_device) {
        dlclose(mt_library); mt_library = NULL;
        return 0;
    }
    reg(mt_device, mt_callback);
    start(mt_device, 0);
    return 1;
}

int id_trackpad_copy(IDFinger *output, int max_points) {
    if (!output || max_points <= 0) return 0;
    pthread_mutex_lock(&mt_lock);
    int count = mt_count < max_points ? mt_count : max_points;
    memcpy(output, mt_fingers, (size_t)count * sizeof(IDFinger));
    pthread_mutex_unlock(&mt_lock);
    return count;
}

void id_trackpad_stop(void) {
    if (mt_device && mt_stop_fn) mt_stop_fn(mt_device);
    if (mt_device && mt_release_fn) mt_release_fn(mt_device);
    mt_device = NULL;
    if (mt_library) dlclose(mt_library);
    mt_library = NULL;
}

#define MAX_SSE_CLIENTS 12
static pthread_mutex_t server_lock = PTHREAD_MUTEX_INITIALIZER;
static int server_fd = -1;
static int clients[MAX_SSE_CLIENTS];
static char html_file[2048];
static char current_json[8192] = "{\"keys\":[],\"fingers\":[],\"trackpad\":false}";
static bool server_running = false;

static void config_socket(int fd) {
    // Avoid a stalled OBS client blocking the app's local live feed indefinitely.
    struct timeval timeout = { .tv_sec = 0, .tv_usec = 150000 };
    setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, sizeof(timeout));
#ifdef SO_NOSIGPIPE
    int yes = 1;
    setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &yes, sizeof(yes));
#endif
}

static bool send_all(int fd, const char *buffer, size_t length) {
    size_t offset = 0;
    while (offset < length) {
        ssize_t n = send(fd, buffer + offset, length - offset, 0);
        if (n < 0 && errno == EINTR) continue;
        if (n <= 0) return false;
        offset += (size_t)n;
    }
    return true;
}

static void close_client(int i) {
    if (clients[i] >= 0) { close(clients[i]); clients[i] = -1; }
}

// Local OBS page must be requested through an explicit loopback host.
// This also reduces risk from DNS-rebinding attempts against the local feed.
static bool allowed_host(const char *request) {
    const char *p = request;
    while ((p = strstr(p, "\r\n")) != NULL) {
        p += 2;
        if (strncasecmp(p, "Host:", 5) != 0) continue;
        p += 5;
        while (*p == ' ' || *p == '\t') p++;
        const char *end = strstr(p, "\r\n");
        if (!end) return false;
        size_t len = (size_t)(end - p);
        return (len == strlen("127.0.0.1:8787") && strncmp(p, "127.0.0.1:8787", len) == 0) ||
               (len == strlen("localhost:8787") && strncmp(p, "localhost:8787", len) == 0);
    }
    return false;
}

static void *handle_http_client(void *arg) {
    int fd = (int)(intptr_t)arg;
    config_socket(fd);
    char request[2048];
    ssize_t n = recv(fd, request, sizeof(request) - 1, 0);
    if (n <= 0) { close(fd); return NULL; }
    request[n] = 0;
    if (!allowed_host(request)) {
        const char *denied = "HTTP/1.1 403 Forbidden\r\nContent-Length: 0\r\nConnection: close\r\n\r\n";
        send_all(fd, denied, strlen(denied));
        close(fd);
        return NULL;
    }
    if (strncmp(request, "GET /events", 11) == 0 &&
        (request[11] == ' ' || request[11] == '?')) {
        const char *headers =
            "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\n"
            "Cache-Control: no-cache, no-transform\r\n"
            "Connection: keep-alive\r\nX-Accel-Buffering: no\r\n\r\n";
        if (!send_all(fd, headers, strlen(headers))) { close(fd); return NULL; }
        pthread_mutex_lock(&server_lock);
        int slot = -1;
        for (int i = 0; i < MAX_SSE_CLIENTS; i++) {
            if (clients[i] < 0) { slot = i; break; }
        }
        if (slot >= 0) {
            clients[slot] = fd;
            char buf[8500];
            int size = snprintf(buf, sizeof(buf), "data: %s\n\n", current_json);
            if (size > 0) send_all(fd, buf, (size_t)size);
        }
        pthread_mutex_unlock(&server_lock);
        if (slot < 0) close(fd);
        return NULL;
    }
    if (strncmp(request, "GET / ", 6) != 0 && strncmp(request, "GET /index.html ", 16) != 0) {
        const char *not_found = "HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n";
        send_all(fd, not_found, strlen(not_found));
        close(fd); return NULL;
    }
    FILE *f = fopen(html_file, "rb");
    if (!f) { close(fd); return NULL; }
    fseek(f, 0, SEEK_END);
    long size = ftell(f);
    rewind(f);
    if (size < 0 || size > 1000000) { fclose(f); close(fd); return NULL; }
    char *html = malloc((size_t)size + 1);
    if (!html) { fclose(f); close(fd); return NULL; }
    size_t read_len = fread(html, 1, (size_t)size, f);
    fclose(f);
    char headers[280];
    snprintf(headers, sizeof(headers),
             "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\n"
             "Content-Length: %zu\r\nCache-Control: no-store\r\n"
             "X-Content-Type-Options: nosniff\r\nConnection: close\r\n\r\n", read_len);
    send_all(fd, headers, strlen(headers));
    send_all(fd, html, read_len);
    free(html);
    close(fd);
    return NULL;
}

static void *http_thread(void *arg) {
    (void)arg;
    while (server_running) {
        int fd = accept(server_fd, NULL, NULL);
        if (fd < 0) {
            if (errno == EINTR) continue;
            break;
        }
        pthread_t t;
        if (pthread_create(&t, NULL, handle_http_client, (void *)(intptr_t)fd) == 0) pthread_detach(t);
        else close(fd);
    }
    return NULL;
}

int id_server_start(const char *html_path, int port) {
    if (!html_path || port < 1024 || port > 65535) return 0;
    pthread_mutex_lock(&server_lock);
    if (server_running) { pthread_mutex_unlock(&server_lock); return 1; }
    snprintf(html_file, sizeof(html_file), "%s", html_path);
    for (int i = 0; i < MAX_SSE_CLIENTS; i++) clients[i] = -1;
    int fd = socket(AF_INET, SOCK_STREAM, 0);
    if (fd < 0) { pthread_mutex_unlock(&server_lock); return 0; }
    config_socket(fd);
    int reuse = 1;
    setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &reuse, sizeof(reuse));
    struct sockaddr_in addr = {.sin_family = AF_INET,
        .sin_port = htons((uint16_t)port), .sin_addr = {.s_addr = htonl(INADDR_LOOPBACK)}};
    if (bind(fd, (struct sockaddr *)&addr, sizeof(addr)) != 0 || listen(fd, 16) != 0) {
        close(fd); pthread_mutex_unlock(&server_lock); return 0;
    }
    server_fd = fd;
    server_running = true;
    pthread_t t;
    if (pthread_create(&t, NULL, http_thread, NULL) != 0) {
        close(fd); server_fd = -1; server_running = false;
        pthread_mutex_unlock(&server_lock); return 0;
    }
    pthread_detach(t);
    pthread_mutex_unlock(&server_lock);
    return 1;
}

void id_server_publish(const char *json) {
    if (!json) return;
    pthread_mutex_lock(&server_lock);
    // State sent over localhost; never written to disk or another service.
    snprintf(current_json, sizeof(current_json), "%s", json);
    char buf[8500];
    int length = snprintf(buf, sizeof(buf), "data: %s\n\n", current_json);
    if (length > 0 && server_running) {
        for (int i = 0; i < MAX_SSE_CLIENTS; i++) {
            if (clients[i] < 0) continue;
            if (!send_all(clients[i], buf, (size_t)length)) close_client(i);
        }
    }
    pthread_mutex_unlock(&server_lock);
}

void id_server_stop(void) {
    pthread_mutex_lock(&server_lock);
    server_running = false;
    if (server_fd >= 0) { close(server_fd); server_fd = -1; }
    for (int i = 0; i < MAX_SSE_CLIENTS; i++) close_client(i);
    pthread_mutex_unlock(&server_lock);
}
