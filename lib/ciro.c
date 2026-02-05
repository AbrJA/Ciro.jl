#include <liburing.h>
#include <stdlib.h>
#include <string.h>
#include <stdio.h>
#include <unistd.h>
#include <arpa/inet.h>
#include <sys/socket.h>

#define BUFFER_SIZE 2048

typedef enum { ACCEPT, READ, WRITE } op_type;

typedef struct {
    op_type type;
    int fd;
    char buffer[BUFFER_SIZE];
    struct sockaddr_in addr;
    socklen_t addr_len;
} conn_t;

struct engine_state {
    struct io_uring ring;
    int server_fd;
};

// Allocation helper for Julia
conn_t* create_connection() {
    return (conn_t*)calloc(1, sizeof(conn_t));
}

void free_connection(conn_t* conn) {
    free(conn);
}

int setup_server_socket(int port) {
    int server_fd = socket(AF_INET, SOCK_STREAM, 0);
    if (server_fd < 0) {
        perror("socket");
        exit(1);
    }

    int opt = 1;
    if (setsockopt(server_fd, SOL_SOCKET, SO_REUSEADDR, &opt, sizeof(opt))) {
        perror("setsockopt reuseaddr");
        exit(1);
    }

    // Enable SO_REUSEPORT for multithraded load balancing
    if (setsockopt(server_fd, SOL_SOCKET, SO_REUSEPORT, &opt, sizeof(opt))) {
        perror("setsockopt reuseport");
        exit(1);
    }

    struct sockaddr_in addr;
    memset(&addr, 0, sizeof(addr));
    addr.sin_family = AF_INET;
    addr.sin_addr.s_addr = INADDR_ANY;
    addr.sin_port = htons(port);

    if (bind(server_fd, (struct sockaddr*)&addr, sizeof(addr)) < 0) {
        perror("bind");
        close(server_fd);
        exit(1);
    }

    if (listen(server_fd, 4096) < 0) {
        perror("listen");
        close(server_fd);
        exit(1);
    }

    return server_fd;
}

// Initialization
struct engine_state* init_engine(int port, int queue_depth) {
    struct engine_state* state = malloc(sizeof(struct engine_state));

    state->server_fd = setup_server_socket(port);

    io_uring_queue_init(queue_depth, &state->ring, 0);
    return state;
}

// Queue an accept request
void queue_accept(struct engine_state* state, conn_t* conn) {
    struct io_uring_sqe *sqe = io_uring_get_sqe(&state->ring);
    conn->type = ACCEPT;
    conn->addr_len = sizeof(conn->addr);

    io_uring_prep_accept(sqe, state->server_fd, (struct sockaddr*)&conn->addr, &conn->addr_len, 0);
    io_uring_sqe_set_data(sqe, conn);
    io_uring_submit(&state->ring);
}

// Queue a read request
void queue_read(struct engine_state* state, conn_t* conn) {
    struct io_uring_sqe *sqe = io_uring_get_sqe(&state->ring);
    conn->type = READ;
    // Read into standard buffer
    io_uring_prep_read(sqe, conn->fd, conn->buffer, BUFFER_SIZE - 1, 0);
    io_uring_sqe_set_data(sqe, conn);
    io_uring_submit(&state->ring);
}

// Queue a write request
void queue_write(struct engine_state* state, conn_t* conn, const char* data, int len) {
    struct io_uring_sqe *sqe = io_uring_get_sqe(&state->ring);
    conn->type = WRITE;

    // For simplicity, we copy data to buffer if needed, OR we can use the pointer passed if it persists
    // Here we assume 'data' is safe or we copy it to conn->buffer if we want full async safety without managing external buffers
    // Let's use conn->buffer for safety in this simple version
    if (len > BUFFER_SIZE) len = BUFFER_SIZE;
    memcpy(conn->buffer, data, len);

    io_uring_prep_write(sqe, conn->fd, conn->buffer, len, 0);
    io_uring_sqe_set_data(sqe, conn);
    io_uring_submit(&state->ring);
}

// Non-blocking check for completions
conn_t* poll_completion(struct engine_state* state, int* res) {
    struct io_uring_cqe *cqe;
    // Peek instead of wait so we don't block the Julia thread
    int ret = io_uring_peek_cqe(&state->ring, &cqe);
    if (ret < 0) return NULL;

    conn_t* conn = (conn_t*)io_uring_cqe_get_data(cqe);
    *res = cqe->res;

    io_uring_cqe_seen(&state->ring, cqe);
    return conn;
}

// gcc -shared -fPIC -o ./lib/ciro.so ./lib/ciro.c -luring
