using Test
using Ciro

# The Backend module requires the C library (lib/ciro.so).
# Gate tests that call ccall behind library availability.
const LIB_AVAILABLE = isfile(Ciro.Backend._LIB)

@testset "Backend" begin

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

    @testset "BufferPool" begin
        pool = BufferPool(; max_size=2, buffer_capacity=1024)

        buf1 = acquire!(pool)
        @test length(buf1) == 1024

        buf2 = acquire!(pool)
        @test length(buf2) == 1024

        release!(pool, buf1)
        release!(pool, buf2)

        # Pool reuses (LIFO)
        buf3 = acquire!(pool)
        @test buf3 === buf2
        release!(pool, buf3)
    end

    @testset "PendingWrites" begin
        pw = PendingWrites(; max_fd=128)

        # Empty by default
        @test pop_pending!(pw, 5) === nothing
        @test should_close!(pw, 5) == false

        # Store and retrieve
        buf = Vector{UInt8}(undef, 64)
        set_pending!(pw, 10, buf)
        @test pop_pending!(pw, 10) === buf
        @test pop_pending!(pw, 10) === nothing  # cleared after pop

        # Close tracking
        mark_close!(pw, 20)
        @test should_close!(pw, 20) == true
        @test should_close!(pw, 20) == false  # cleared after check

        # Auto-resize for large fds
        big_buf = Vector{UInt8}(undef, 32)
        set_pending!(pw, 200, big_buf)
        @test pop_pending!(pw, 200) === big_buf
    end

    if LIB_AVAILABLE
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
            @test conn_buffer(conn) != C_NULL

            free_connection!(conn)
        end

        @testset "ConnectionPool" begin
            pool = ConnectionPool(; max_size=4)

            c1 = acquire!(pool)
            c2 = acquire!(pool)
            @test c1.ptr != c2.ptr

            release!(pool, c1)
            release!(pool, c2)

            # LIFO reuse
            c3 = acquire!(pool)
            @test c3.ptr == c2.ptr

            c4 = acquire!(pool)
            @test c4.ptr == c1.ptr

            free_connection!(c3)
            free_connection!(c4)
        end
    else
        @info "Skipping ccall-based Backend tests (lib/ciro.so not found)"
    end
end
