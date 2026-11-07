using Microsoft.AspNetCore.HttpOverrides;

var builder = WebApplication.CreateBuilder(args);

// Behind an AWS load balancer, trust the X-Forwarded-* headers so the app
// knows the original request scheme (HTTPS) and client IP.
builder.Services.Configure<ForwardedHeadersOptions>(options =>
{
    options.ForwardedHeaders = ForwardedHeaders.XForwardedFor | ForwardedHeaders.XForwardedProto;
    options.KnownIPNetworks.Clear();
    options.KnownProxies.Clear();
});

builder.Services.AddHealthChecks();

var app = builder.Build();

app.UseForwardedHeaders();

var version = Environment.GetEnvironmentVariable("APP_VERSION") ?? "local";

app.MapGet("/", () =>
{
    // Block body with separate statements, so breakpoints can bind on these lines.
    var response = new
    {
        message = "Hello from ASP.NET Core on AWS ECS V2!",
        version,
        machine = Environment.MachineName,
        utc = DateTime.UtcNow
    };

    return Results.Ok(response);
});

// Used by the load balancer / ECS to decide whether the container is healthy.
app.MapHealthChecks("/health");

app.Run();
