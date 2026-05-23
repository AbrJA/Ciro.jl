using Test
using CiroBackend
using Sockets

@testset "CiroBackend" begin

    @testset "Types" begin
        @test ACCEPT == EventType(0)
        @test READ == EventType(1)
        @test WRITE == EventType(2)

        # CompletionEvent is a value type (stack-allocated)
        evt = CompletionEvent(Ptr{Cvoid}(1), Cint(42), READ)
        @test evt.conn == Ptr{Cvoid}(1)
        @test evt.result == 42
        @test evt.op_type == READ

        # Connection equality
        c1 = Connection(Ptr{Cvoid}(100))
        c2 = Connection(Ptr{Cvoid}(100))
        c3 = Connection(Ptr{Cvoid}(200))
        @test c1 == c2
        @test c1 != c3
    end

    @testset "Engine lifecycle" begin
        engine = init_engine(29001)
        @test engine !== nothing
        @test engine isa Engine
        @test engine.ptr != C_NULL

        close_engine!(engine)
        @test engine.ptr == C_NULL

        # Double close is safe
        close_engine!(engine)
    end

    @testset "Connection management" begin
        conn = create_connection()
        @test conn.ptr != C_NULL

        set_conn_fd!(conn, 42)
        @test conn_fd(conn) == 42

        set_conn_op!(conn, WRITE)
        @test conn_buffer(conn) != C_NULL  # buffer exists

        free_connection!(conn)
    end

    @testset "ConnectionPool" begin
        pool = ConnectionPool(; max_size=4)

        # Acquire creates new
        c1 = acquire!(pool)
        c2 = acquire!(pool)
        @test c1.ptr != c2.ptr

        # Release puts back
        release!(pool, c1)
        release!(pool, c2)

        # Acquire reuses from pool
        c3 = acquire!(pool)
        @test c3.ptr == c2.ptr  # LIFO

        c4 = acquire!(pool)
        @test c4.ptr == c1.ptr

        # Cleanup
        free_connection!(c3)
        free_connection!(c4)
    end

    @testset "BufferPool" begin
        pool = BufferPool(; max_size=2, buffer_capacity=1024)

        buf1 = acquire!(pool)
        @test length(buf1) == 1024

        buf2 = acquire!(pool)
        @test length(buf2) == 1024

        release!(pool, buf1)
        release!(pool, buf2)

        # Pool reuses
        buf3 = acquire!(pool)
        @test buf3 === buf2  # Same object (LIFO)
        release!(pool, buf3)
    end

    @testset "PendingWrites" begin
        pw = PendingWrites(; max_fd=128)

        # Empty by default
        @test pop_pending!(pw, 5) === nothing
        @test should_close!(pw, 5) == false

        # Set and pop
        buf = UInt8[1, 2, 3]
        set_pending!(pw, 10, buf)
        @test pop_pending!(pw, 10) === buf
        @test pop_pending!(pw, 10) === nothing  # Gone after pop

        # Close flag
        mark_close!(pw, 20)
        @test should_close!(pw, 20) == true
        @test should_close!(pw, 20) == false  # Cleared after check

        # Auto-resize beyond initial capacity
        big_buf = UInt8[4, 5, 6]
        set_pending!(pw, 200, big_buf)
        @test pop_pending!(pw, 200) === big_buf
    end

    @testset "Engine I/O - accept and read" begin
        # Start engine on a port
        engine = init_engine(29002; queue_depth=64)
        @test engine !== nothing

        # Queue multishot accept
        accept_conn = create_connection()
        queue_multishot_accept!(engine, accept_conn)

        # Connect a client
        client = Sockets.connect("127.0.0.1", 29002)
        @test isopen(client)

        # Wait for accept completion
        event = wait_completion(engine; timeout_ms=1000)
        @test event !== nothing
        @test event.result > 0  # fd of accepted client

        client_fd = event.result
        configure_socket!(client_fd)

        # Queue a read on the accepted connection
        read_conn = create_connection()
        set_conn_fd!(read_conn, client_fd)
        set_conn_op!(read_conn, READ)
        queue_read!(engine, read_conn)
        submit!(engine)

        # Send data from client
        write(client, "Hello from client")

        # Wait for read completion
        event = wait_completion(engine; timeout_ms=1000)
        @test event !== nothing
        @test event.result > 0  # bytes read

        # Verify data
        buf_ptr = conn_buffer(Connection(event.conn))
        data = unsafe_string(buf_ptr, Int(event.result))
        @test data == "Hello from client"

        # Cleanup
        close(client)
        close_fd!(client_fd)
        free_connection!(read_conn)
        free_connection!(accept_conn)
        close_engine!(engine)
    end

    @testset "Engine I/O - write" begin
        engine = init_engine(29003; queue_depth=64)
        @test engine !== nothing

        accept_conn = create_connection()
        queue_multishot_accept!(engine, accept_conn)

        # Connect client
        client = Sockets.connect("127.0.0.1", 29003)

        # Accept
        event = wait_completion(engine; timeout_ms=1000)
        @test event !== nothing
        client_fd = event.result

        # Write from server to client
        write_conn = create_connection()
        set_conn_fd!(write_conn, client_fd)
        set_conn_op!(write_conn, WRITE)

        msg = Vector{UInt8}("Server says hi!")
        GC.@preserve msg begin
            queue_write!(engine, write_conn, pointer(msg), length(msg))
            submit!(engine)
        end

        # Wait for write completion
        event = wait_completion(engine; timeout_ms=1000)
        @test event !== nothing
        @test event.result == length(msg)

        # Client reads the data
        received = String(readavailable(client))
        @test received == "Server says hi!"

        # Cleanup
        close(client)
        close_fd!(client_fd)
        free_connection!(write_conn)
        free_connection!(accept_conn)
        close_engine!(engine)
    end

    @testset "poll_completion - non-blocking" begin
        engine = init_engine(29004; queue_depth=64)
        @test engine !== nothing

        # No events queued → poll returns nothing
        @test poll_completion(engine) === nothing

        close_engine!(engine)
    end

end
