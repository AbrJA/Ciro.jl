module Clustering

using ..Servers: start_server, stop_server
using ..Router: AbstractApp

export cluster_server

"""
    cluster_server(app, port; workers=Sys.CPU_THREADS)

Start multiple processes via `fork()`, each running `start_server`.
Uses `SO_REUSEPORT` (enabled in the C layer) for kernel load balancing.

The master process runs as worker 1 and waits for all children on exit.
"""
function cluster_server(app::AbstractApp, port::Int=8080;
                        workers::Int=Sys.CPU_THREADS)
    workers < 1 && error("workers must be >= 1")
    workers == 1 && return start_server(app, port)

    Sys.islinux() || error("cluster_server requires Linux (fork + SO_REUSEPORT)")

    println("🚀 Ciro cluster: spawning $workers processes on port $port")
    child_pids = Int[]

    for i in 2:workers
        pid = ccall(:fork, Cint, ())
        if pid == 0
            # Child process — run server and exit
            try
                start_server(app, port)
            catch e
                e isa InterruptException || @error "Worker $i crashed" exception=e
            end
            ccall(:_exit, Cvoid, (Cint,), 0)
        elseif pid > 0
            push!(child_pids, Int(pid))
        else
            @error "fork() failed for worker $i"
        end
    end

    # Master = worker 1
    try
        start_server(app, port)
    catch e
        e isa InterruptException || rethrow(e)
    finally
        # Signal children and wait
        println("🛑 Cluster shutting down...")
        for pid in child_pids
            ccall(:kill, Cint, (Cint, Cint), pid, 15)  # SIGTERM
        end
        status = Ref{Cint}(0)
        for pid in child_pids
            ccall(:waitpid, Cint, (Cint, Ref{Cint}, Cint), pid, status, 0)
        end
        println("✅ All workers stopped")
    end
end

end
