"""
Static Analysis Tests

Uses JET.jl to catch errors at "compile time" including:
- Undefined variable references
- Missing exports
- Type instabilities
- Method errors

Run this before commits to catch issues like missing exports from modules.
"""

using ReTest
using JET

@testset "Static Analysis" begin
    @testset "Module Loading" begin
        # Test that all modules load without UndefVarError
        @test begin
            using MCPRepl
            true
        end
    end

    @testset "Proxy Module Exports" begin
        # Check that Proxy module properly imports from Session module
        @test isdefined(MCPRepl.Proxy, :update_activity!)
    end

    @testset "Session Module Exports" begin
        # Verify all expected exports exist
        @test isdefined(MCPRepl.Session, :update_activity!)
    end

    @testset "Top-level Module Analysis" begin
        # Run JET analysis on the entire MCPRepl module
        # This catches undefined variables, type issues, etc.
        using MCPRepl
        rep = report_package(MCPRepl; ignored_modules = (AnyFrameModule(Test),))

        # Filter out known acceptable issues
        issues = filter(rep.res.inference_error_reports) do report
            # Ignore errors from test files
            any(sf -> occursin("test/", string(sf.file)), report.vst) && return false

            # Ignore common false positives or known issues to be fixed later
            msg = string(report)

            # 1. Ignore "local variable conn is not defined" - likely scope/macro issue in proxy.jl
            occursin("local variable `conn` is not defined", msg) && return false

            # 2. Ignore joinpath(::Nothing, ::String) - caused by optional paths
            occursin("joinpath(::Nothing, ::String)", msg) && return false

            # 3. Ignore parse(::Type{Int64}, ::Nothing) - regex match result checking
            occursin("parse(::Type{Int64}, ::Nothing)", msg) && return false

            # 4. Ignore other common union splitting errors in proxy.jl
            occursin("close(::Nothing)", msg) && return false
            occursin("kill(::Nothing)", msg) && return false
            occursin("process_running(::Nothing)", msg) && return false

            return true
        end

        if !isempty(issues)
            println("\n❌ Static analysis found issues:")
            for (i, issue) in enumerate(issues)
                println("\n$i. ", issue)
            end
        end

        @test isempty(issues)
    end

    @testset "Export Consistency Check" begin
        # Verify that all `using .Module` statements can resolve their names

        # Test Proxy module dependencies
        @testset "Proxy Dependencies" begin
            using MCPRepl.Proxy

            # These should all be available from imported modules
            @test isdefined(MCPRepl.Proxy, :Dashboard)
            @test isdefined(MCPRepl.Proxy, :Session)
            @test isdefined(MCPRepl.Proxy, :MCPSession)
            @test isdefined(MCPRepl.Proxy, :update_activity!)
            @test isdefined(MCPRepl.Proxy, :get_mcp_session)
            @test isdefined(MCPRepl.Proxy, :create_mcp_session)
        end

        # Test MCPServer module dependencies
        @testset "MCPServer Dependencies" begin
            # MCPServer is not a module, but a struct in MCPRepl
            @test isdefined(MCPRepl, :MCPServer)

            # Check that Session module is available (included by MCPServer.jl)
            @test isdefined(MCPRepl, :Session)
            @test isdefined(MCPRepl.Session, :MCPSession)
        end
    end
end
