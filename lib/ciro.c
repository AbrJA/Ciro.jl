#include <liburing.h>
#include <stdlib.h>
#include <string.h>
#include <stdio.h>
#include <unistd.h>
#include <arpa/inet.h>
#include <sys/socket.h>
#include <netinet/tcp.h>
#include <errno.h>
#include <signal.h>

#define BUFFER_SIZE 65536

typedef enum { ACCEPT, READ, WRITE } op_type;

typedef struct {
    op_type type;
    int fd;
    char buffer[BUFFER_SIZE];
    int flags;  // Bit flags: CLOSE=1, WS=2, TLS=4
    struct sockaddr_in addr;
    socklen_t addr_len;
} conn_t;

struct engine_state {
    struct io_uring ring;
    int server_fd;
};

static inline struct io_uring_sqe* get_sqe_submit_retry(struct io_uring* ring) {
    struct io_uring_sqe* sqe = io_uring_get_sqe(ring);
    if (sqe) return sqe;
    if (io_uring_submit(ring) < 0) return NULL;
    return io_uring_get_sqe(ring);
}

// Allocation helper for Julia
conn_t* create_connection() {
    return (conn_t*)calloc(1, sizeof(conn_t));
}

void free_connection(conn_t* conn) {
    free(conn);
}

// --- Accessors for Julia (conn_t is opaque from Julia's perspective) ---
int get_conn_op_type(conn_t* conn) { return (int)conn->type; }
int get_conn_fd(conn_t* conn) { return conn->fd; }
char* get_conn_buffer(conn_t* conn) { return conn->buffer; }
int get_conn_buffer_size() { return BUFFER_SIZE; }
void set_conn_op_type(conn_t* conn, int t) { conn->type = (op_type)t; }
void set_conn_fd(conn_t* conn, int fd) { conn->fd = fd; }
int get_conn_flags(conn_t* conn) { return conn->flags; }
void set_conn_flags(conn_t* conn, int flags) { conn->flags = flags; }

static void set_tcp_nodelay(int fd) {
    int flag = 1;
    setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &flag, sizeof(flag));
}

int setup_server_socket(int port) {
    int server_fd = socket(AF_INET, SOCK_STREAM | SOCK_NONBLOCK, 0);
    if (server_fd < 0) {
        perror("socket");
        return -1;
    }

    int opt = 1;
    if (setsockopt(server_fd, SOL_SOCKET, SO_REUSEADDR, &opt, sizeof(opt))) {
        perror("setsockopt reuseaddr");
        close(server_fd);
        return -1;
    }

    // Enable SO_REUSEPORT for multithreaded load balancing
    if (setsockopt(server_fd, SOL_SOCKET, SO_REUSEPORT, &opt, sizeof(opt))) {
        perror("setsockopt reuseport");
        close(server_fd);
        return -1;
    }

    struct sockaddr_in addr;
    memset(&addr, 0, sizeof(addr));
    addr.sin_family = AF_INET;
    addr.sin_addr.s_addr = INADDR_ANY;
    addr.sin_port = htons(port);

    if (bind(server_fd, (struct sockaddr*)&addr, sizeof(addr)) < 0) {
        perror("bind");
        close(server_fd);
        return -1;
    }

    if (listen(server_fd, 8192) < 0) {
        perror("listen");
        close(server_fd);
        return -1;
    }

    signal(SIGPIPE, SIG_IGN);

    return server_fd;
}

// Initialization - returns NULL on failure
struct engine_state* init_engine(int port, int queue_depth) {
    struct engine_state* state = malloc(sizeof(struct engine_state));
    if (!state) {
        return NULL;
    }

    state->server_fd = setup_server_socket(port);
    if (state->server_fd < 0) {
        free(state);
        return NULL;
    }

    // Plain init — avoid COOP_TASKRUN which conflicts with Julia's signal handlers
    int ret = io_uring_queue_init(queue_depth, &state->ring, 0);
    if (ret < 0) {
        close(state->server_fd);
        free(state);
        return NULL;
    }

    return state;
}

// Cleanup - properly releases all resources
void cleanup_engine(struct engine_state* state) {
    if (!state) return;
    io_uring_queue_exit(&state->ring);
    if (state->server_fd >= 0) {
        close(state->server_fd);
    }
    free(state);
}

// Get server fd for external shutdown signaling
int get_server_fd(struct engine_state* state) {
    return state ? state->server_fd : -1;
}

// Queue an accept request
void queue_accept(struct engine_state* state, conn_t* conn) {
    struct io_uring_sqe *sqe = get_sqe_submit_retry(&state->ring);
    if (!sqe) return;
    conn->type = ACCEPT;
    conn->addr_len = sizeof(conn->addr);

    io_uring_prep_accept(sqe, state->server_fd, (struct sockaddr*)&conn->addr, &conn->addr_len, 0);
    io_uring_sqe_set_data(sqe, conn);
    io_uring_submit(&state->ring);
}

// Set TCP_NODELAY on accepted connections (exposed to Julia)
void configure_client_socket(int fd) {
    set_tcp_nodelay(fd);
}

// Queue a read request
void queue_read(struct engine_state* state, conn_t* conn) {
    struct io_uring_sqe *sqe = get_sqe_submit_retry(&state->ring);
    if (!sqe) return;
    conn->type = READ;
    io_uring_prep_read(sqe, conn->fd, conn->buffer, BUFFER_SIZE, 0);
    io_uring_sqe_set_data(sqe, conn);
}

// Queue a write request - ZERO COPY
// Caller (Julia) MUST ensure data stays alive until completion!
void queue_write(struct engine_state* state, conn_t* conn, const char* data, int len) {
    struct io_uring_sqe *sqe = get_sqe_submit_retry(&state->ring);
    if (!sqe) return;
    conn->type = WRITE;

    io_uring_prep_write(sqe, conn->fd, data, len, 0);
    io_uring_sqe_set_data(sqe, conn);
}

// 2. Add bulk submission support
int submit_pending(struct engine_state* state) {
    return io_uring_submit(&state->ring);
}

// 3. Wait for completion — no signal mask overhead (EINTR is handled by retry)
conn_t* wait_completion(struct engine_state* state, int* res, int timeout_ms) {
    struct io_uring_cqe *cqe;
    struct __kernel_timespec ts = {
        .tv_sec = timeout_ms / 1000,
        .tv_nsec = (long long)(timeout_ms % 1000) * 1000000
    };

    int ret;
    do {
        ret = io_uring_wait_cqe_timeout(&state->ring, &cqe, &ts);
    } while (ret == -EINTR);

    if (ret < 0) {
        return NULL;
    }

    conn_t* conn = (conn_t*)io_uring_cqe_get_data(cqe);
    *res = cqe->res;
    io_uring_cqe_seen(&state->ring, cqe);
    return conn;
}

// Fast batch drain: get up to `max` completions at once, returns count
int drain_completions(struct engine_state* state, conn_t** conns, int* results, int max) {
    int count = 0;
    struct io_uring_cqe *cqe;

    while (count < max) {
        int ret = io_uring_peek_cqe(&state->ring, &cqe);
        if (ret < 0) break;

        conns[count] = (conn_t*)io_uring_cqe_get_data(cqe);
        results[count] = cqe->res;
        io_uring_cqe_seen(&state->ring, cqe);
        count++;
    }
    return count;
}

// Combined: accept fd → set fd on conn → set TCP_NODELAY → queue read.
void accept_and_queue_read(struct engine_state* state, conn_t* conn, int client_fd) {
    set_tcp_nodelay(client_fd);   // must happen before first read
    conn->fd = client_fd;
    conn->type = READ;

    struct io_uring_sqe *sqe = get_sqe_submit_retry(&state->ring);
    if (!sqe) return;
    io_uring_prep_read(sqe, client_fd, conn->buffer, BUFFER_SIZE, 0);
    io_uring_sqe_set_data(sqe, conn);
}

// Combined: queue write + mark for close after (via io_uring linked ops)
void queue_write_and_close(struct engine_state* state, conn_t* conn, const char* data, int len) {
    // First: queue the write
    struct io_uring_sqe *sqe = get_sqe_submit_retry(&state->ring);
    if (!sqe) return;
    conn->type = WRITE;
    io_uring_prep_write(sqe, conn->fd, data, len, 0);
    io_uring_sqe_set_data(sqe, conn);
    // Link: next op executes only after this completes
    sqe->flags |= IOSQE_IO_LINK;

    // Second: queue close (linked, fires after write completes)
    sqe = get_sqe_submit_retry(&state->ring);
    if (!sqe) return;
    io_uring_prep_close(sqe, conn->fd);
    io_uring_sqe_set_data(sqe, conn);
}

// 4. Use io_uring multishot accept (kernel 5.19+)
void queue_multishot_accept(struct engine_state* state, conn_t* conn) {
    struct io_uring_sqe *sqe = get_sqe_submit_retry(&state->ring);
    if (!sqe) return;

    conn->type = ACCEPT;
    // Multishot accept: Keep issuing accepts!
    io_uring_prep_multishot_accept(sqe, state->server_fd, NULL, NULL, 0);
    io_uring_sqe_set_data(sqe, conn);
    io_uring_submit(&state->ring);
}

// Non-blocking check for completions
conn_t* poll_completion(struct engine_state* state, int* res) {
    struct io_uring_cqe *cqe;
    int ret = io_uring_peek_cqe(&state->ring, &cqe);
    if (ret < 0) return NULL;

    conn_t* conn = (conn_t*)io_uring_cqe_get_data(cqe);
    *res = cqe->res;

    io_uring_cqe_seen(&state->ring, cqe);
    return conn;
}

// Queue read after write completion (keep-alive path)
void queue_read_reuse(struct engine_state* state, conn_t* conn) {
    conn->type = READ;
    struct io_uring_sqe *sqe = get_sqe_submit_retry(&state->ring);
    if (!sqe) return;
    io_uring_prep_read(sqe, conn->fd, conn->buffer, BUFFER_SIZE, 0);
    io_uring_sqe_set_data(sqe, conn);
}

// Compile: gcc -shared -fPIC -O3 -o ./lib/ciro.so ./lib/ciro.c -luring
