# mrmd-julia

Julia runtime server for MRMD.

One `mrmd-julia` server process = one Julia runtime namespace.
If you need another isolated namespace, start another server process on another port.

Implements MRP (MRMD Runtime Protocol) for:
- code execution
- SSE-compatible execution responses
- completions
- hover and inspection
- variable inspection
- plot/asset capture (Plots.jl, Makie.jl)
- runtime reset

## Requirements

- Julia 1.9 or later
- HTTP.jl, JSON3.jl, StructTypes.jl

## Installation

```bash
cd mrmd-julia
julia --project=. -e 'using Pkg; Pkg.instantiate()'
```

## Usage

```bash
julia --project=. bin/mrmd-julia --port 8000 --cwd /path/to/project
# or
./bin/mrmd-julia --port 8000
```

From Julia:

```julia
using MrmdJulia
start_server(port=8000, host="127.0.0.1", cwd=pwd())
```

## MRP Endpoints

All endpoints are under `/mrp/v1/`:

| Endpoint | Method | Description |
|----------|--------|-------------|
| `/capabilities` | GET | Server capabilities |
| `/reset` | POST | Reset runtime namespace |
| `/execute` | POST | Execute code |
| `/execute/stream` | POST | Execute code with SSE-compatible response |
| `/interrupt` | POST | Interrupt execution |
| `/complete` | POST | Get completions |
| `/inspect` | POST | Get detailed info |
| `/hover` | POST | Get hover info |
| `/variables` | POST | List variables |
| `/variables/{name}` | POST | Get variable detail |
| `/is_complete` | POST | Check if code is complete |
| `/format` | POST | Format code |
| `/history` | POST | Browse persistent Julia REPL history |
| `/assets/{path}` | GET | Serve saved assets |

## Examples

### Execute

```julia
POST /mrp/v1/execute/stream
{
  "code": "for i in 1:5\n  println(i)\n  sleep(0.5)\nend"
}
```

### Complete

```julia
POST /mrp/v1/complete
{
  "code": "prin",
  "cursor": 4
}
```

### Variables

```julia
POST /mrp/v1/variables
{}
```

### Reset

```julia
POST /mrp/v1/reset
{}
```

History is backed by Julia's native REPL history file (`REPL.find_hist_file()`, typically `~/.julia/logs/repl_history.jl`), so `/history` survives runtime restarts and `POST /reset`.

## Plot Capture

When using Plots.jl or Makie.jl, plots are automatically saved as assets:

```julia
using Plots
plot(1:10, rand(10))
```

## Protocol

This server implements the shared MRP spec at:
- `../spec/mrp-protocol.md`

## License

MIT
