# MRP HTTP Server for Julia runtime
#
# Implements the MRMD Runtime Protocol (MRP) over HTTP.
# One server process = one Julia worker = one runtime namespace.
# Start another server process for another namespace.
#
# Note: types.jl and worker.jl are included by MrmdJulia.jl before this file

using HTTP
using JSON3
using Dates
using Sockets

"""
MRP Server for Julia.
"""
mutable struct MRPServer
    cwd::String
    assets_dir::String
    worker::JuliaWorker
end

function MRPServer(; cwd::String=pwd(), assets_dir::String=joinpath(cwd, ".mrmd-assets"))
    isdir(assets_dir) || mkpath(assets_dir)

    worker = JuliaWorker(cwd=cwd, assets_dir=assets_dir)
    MRPServer(cwd, assets_dir, worker)
end

"""
Get server capabilities.
"""
function get_capabilities(server::MRPServer)::Capabilities
    Capabilities(
        runtime="mrmd-julia",
        version="0.1.0",
        languages=["julia", "jl"],
        features=Features(),
        environment=Environment(
            cwd=server.cwd,
            executable=Base.julia_cmd().exec[1]
        )
    )
end

# =========================================================================
# Route Handlers
# =========================================================================

function handle_capabilities(server::MRPServer, req::HTTP.Request)
    caps = get_capabilities(server)
    return HTTP.Response(200, json_headers(), JSON3.write(caps))
end

function handle_reset(server::MRPServer, req::HTTP.Request)
    reset!(server.worker)
    return HTTP.Response(200, json_headers(), JSON3.write(Dict("success" => true)))
end

function handle_execute(server::MRPServer, req::HTTP.Request)
    body = JSON3.read(String(req.body))

    code = get(body, :code, "")
    store_history = get(body, :storeHistory, true)
    exec_id = get(body, :execId, string(time_ns()))

    # Run evaluation in its own task so the HTTP server can continue
    # servicing requests like /interrupt while code is executing.
    result = fetch(@async execute(server.worker, code; store_history=store_history, exec_id=exec_id))
    return HTTP.Response(200, json_headers(), JSON3.write(result))
end

function handle_execute_stream(server::MRPServer, req::HTTP.Request)
    # NOTE: True incremental SSE streaming in HTTP.jl is still not wired here.
    # For now we execute eagerly and return SSE-compatible events.
    body = JSON3.read(String(req.body))

    code = get(body, :code, "")
    store_history = get(body, :storeHistory, true)
    exec_id = get(body, :execId, string(time_ns()))

    # Run evaluation in its own task so /interrupt can be serviced while
    # this request is waiting on the result.
    result = fetch(@async execute(server.worker, code; store_history=store_history, exec_id=exec_id))

    sse_body = IOBuffer()
    write_sse_event(sse_body, "start", Dict(
        "execId" => exec_id,
        "timestamp" => Dates.format(now(UTC), ISODateTimeFormat)
    ))

    if !isempty(result.stdout)
        write_sse_event(sse_body, "stdout", Dict(
            "content" => result.stdout,
            "accumulated" => result.stdout
        ))
    end
    if !isempty(result.stderr)
        write_sse_event(sse_body, "stderr", Dict(
            "content" => result.stderr,
            "accumulated" => result.stderr
        ))
    end

    if result.success
        write_sse_event(sse_body, "result", result)
    else
        write_sse_event(sse_body, "error", result.error)
    end
    write_sse_event(sse_body, "done", Dict())

    return HTTP.Response(200, sse_headers(), String(take!(sse_body)))
end

function handle_interrupt(server::MRPServer, req::HTTP.Request)
    interrupted = interrupt!(server.worker)
    return HTTP.Response(200, json_headers(), JSON3.write(Dict("interrupted" => interrupted)))
end

function handle_complete(server::MRPServer, req::HTTP.Request)
    body = JSON3.read(String(req.body))

    code = get(body, :code, "")
    cursor = get(body, :cursor, length(code))

    result = complete(server.worker, code, cursor)
    return HTTP.Response(200, json_headers(), JSON3.write(result))
end

function handle_inspect(server::MRPServer, req::HTTP.Request)
    body = JSON3.read(String(req.body))

    code = get(body, :code, "")
    cursor = get(body, :cursor, length(code))
    detail = get(body, :detail, 1)

    result = inspect(server.worker, code, cursor; detail=detail)
    return HTTP.Response(200, json_headers(), JSON3.write(result))
end

function handle_hover(server::MRPServer, req::HTTP.Request)
    body = JSON3.read(String(req.body))

    code = get(body, :code, "")
    cursor = get(body, :cursor, length(code))

    result = hover(server.worker, code, cursor)
    return HTTP.Response(200, json_headers(), JSON3.write(result))
end

function handle_variables(server::MRPServer, req::HTTP.Request)
    body = JSON3.read(String(req.body))
    filter_config = get(body, :filter, nothing)
    name_pattern = filter_config === nothing ? nothing : get(filter_config, :namePattern, nothing)

    result = get_variables(server.worker; filter_pattern=name_pattern)
    return HTTP.Response(200, json_headers(), JSON3.write(result))
end

function handle_variable_detail(server::MRPServer, req::HTTP.Request, name::String)
    body = JSON3.read(String(req.body))
    path = get(body, :path, nothing)

    result = get_variable_detail(server.worker, name; path=path)
    return HTTP.Response(200, json_headers(), JSON3.write(result))
end

function handle_is_complete(server::MRPServer, req::HTTP.Request)
    body = JSON3.read(String(req.body))
    code = get(body, :code, "")

    result = is_complete(server.worker, code)
    return HTTP.Response(200, json_headers(), JSON3.write(result))
end

function handle_format(server::MRPServer, req::HTTP.Request)
    body = JSON3.read(String(req.body))
    code = get(body, :code, "")

    return HTTP.Response(200, json_headers(), JSON3.write(Dict(
        "formatted" => code,
        "changed" => false,
        "error" => "Formatting not yet implemented"
    )))
end

function handle_history(server::MRPServer, req::HTTP.Request)
    body = JSON3.read(String(req.body))
    n = Int(get(body, :n, 20))
    pattern = get(body, :pattern, nothing)
    before = haskey(body, :before) && !isnothing(get(body, :before, nothing)) ? Int(get(body, :before, 0)) : nothing

    result = get_history(server.worker; n=n, pattern=pattern, before=before)
    return HTTP.Response(200, json_headers(), JSON3.write(result))
end

function handle_assets(server::MRPServer, req::HTTP.Request, asset_path::String)
    full_path = joinpath(server.assets_dir, asset_path)

    if !isfile(full_path)
        return HTTP.Response(404, json_headers(), JSON3.write(Dict("error" => "Asset not found")))
    end

    ext = lowercase(splitext(full_path)[2])
    content_type = get(Dict(
        ".png" => "image/png",
        ".jpg" => "image/jpeg",
        ".jpeg" => "image/jpeg",
        ".svg" => "image/svg+xml",
        ".html" => "text/html",
        ".json" => "application/json"
    ), ext, "application/octet-stream")

    content = read(full_path)
    return HTTP.Response(200, [
        "Content-Type" => content_type,
        "Access-Control-Allow-Origin" => "*"
    ], content)
end

# =========================================================================
# HTTP Helpers
# =========================================================================

function json_headers()
    [
        "Content-Type" => "application/json",
        "Access-Control-Allow-Origin" => "*",
        "Access-Control-Allow-Methods" => "*",
        "Access-Control-Allow-Headers" => "*"
    ]
end

function sse_headers()
    [
        "Content-Type" => "text/event-stream",
        "Cache-Control" => "no-cache",
        "Connection" => "keep-alive",
        "Access-Control-Allow-Origin" => "*",
        "Access-Control-Allow-Methods" => "*",
        "Access-Control-Allow-Headers" => "*"
    ]
end

function write_sse_event(io, event::String, data)
    write(io, "event: $event\n")
    write(io, "data: $(JSON3.write(data))\n\n")
    flush(io)
end

# =========================================================================
# Router
# =========================================================================

function create_router(server::MRPServer)
    function router(req::HTTP.Request)
        if req.method == "OPTIONS"
            return HTTP.Response(200, [
                "Access-Control-Allow-Origin" => "*",
                "Access-Control-Allow-Methods" => "GET, POST, DELETE, OPTIONS",
                "Access-Control-Allow-Headers" => "*",
                "Access-Control-Max-Age" => "86400"
            ])
        end

        path = HTTP.URI(req.target).path
        method = req.method

        try
            if path == "/mrp/v1/capabilities" && method == "GET"
                return handle_capabilities(server, req)
            elseif path == "/mrp/v1/reset" && method == "POST"
                return handle_reset(server, req)
            elseif path == "/mrp/v1/execute" && method == "POST"
                return handle_execute(server, req)
            elseif path == "/mrp/v1/execute/stream" && method == "POST"
                return handle_execute_stream(server, req)
            elseif path == "/mrp/v1/interrupt" && method == "POST"
                return handle_interrupt(server, req)
            elseif path == "/mrp/v1/complete" && method == "POST"
                return handle_complete(server, req)
            elseif path == "/mrp/v1/inspect" && method == "POST"
                return handle_inspect(server, req)
            elseif path == "/mrp/v1/hover" && method == "POST"
                return handle_hover(server, req)
            elseif path == "/mrp/v1/variables" && method == "POST"
                return handle_variables(server, req)
            elseif startswith(path, "/mrp/v1/variables/") && method == "POST"
                name = String(split(path, "/")[5])
                return handle_variable_detail(server, req, name)
            elseif path == "/mrp/v1/is_complete" && method == "POST"
                return handle_is_complete(server, req)
            elseif path == "/mrp/v1/format" && method == "POST"
                return handle_format(server, req)
            elseif path == "/mrp/v1/history" && method == "POST"
                return handle_history(server, req)
            elseif startswith(path, "/mrp/v1/assets/") && method == "GET"
                asset_path = join(split(path, "/")[5:end], "/")
                return handle_assets(server, req, asset_path)
            end

            return HTTP.Response(404, json_headers(), JSON3.write(Dict("error" => "Not found")))
        catch e
            @error "Request error" exception=(e, catch_backtrace())
            return HTTP.Response(500, json_headers(), JSON3.write(Dict(
                "error" => string(typeof(e)),
                "message" => string(e)
            )))
        end
    end

    return router
end

# =========================================================================
# Server Entry Point
# =========================================================================

"""
Start the MRP server.

# Arguments
- `port::Int`: Port to listen on (default: 8000)
- `host::String`: Host to bind to (default: "127.0.0.1")
- `cwd::String`: Working directory (default: current directory)
- `assets_dir::String`: Directory for assets (default: cwd/.mrmd-assets)
"""
function start_server(;
    port::Int=8000,
    host::String="127.0.0.1",
    cwd::String=pwd(),
    assets_dir::String=joinpath(cwd, ".mrmd-assets")
)
    server = MRPServer(cwd=cwd, assets_dir=assets_dir)
    router = create_router(server)

    @info "Starting mrmd-julia MRP server" host=host port=port cwd=cwd
    HTTP.serve(router, host, port)
end

export start_server
