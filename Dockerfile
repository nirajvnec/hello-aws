# ---- Build stage ----
FROM mcr.microsoft.com/dotnet/sdk:10.0 AS build
WORKDIR /src

# Restore first so this layer is cached when only code changes
COPY HelloAws/HelloAws.csproj HelloAws/
RUN dotnet restore HelloAws/HelloAws.csproj

COPY HelloAws/ HelloAws/
RUN dotnet publish HelloAws/HelloAws.csproj -c Release -o /app/publish --no-restore

# ---- Base runtime (shared by debug and final) ----
FROM mcr.microsoft.com/dotnet/aspnet:10.0 AS base
WORKDIR /app
ENV ASPNETCORE_HTTP_PORTS=8080
EXPOSE 8080

# ---- Debug stage (VS Code container debugging only) ----
# Needs curl + unzip to fetch vsdbg, and root to create /remote_debugger.
# The app itself is mounted in by VS Code, so nothing is copied here.
FROM base AS debug
USER root
RUN apt-get update && apt-get install -y --no-install-recommends curl unzip \
    && rm -rf /var/lib/apt/lists/*

# ---- Final stage (production, used by ECS) ----
# Kept LAST so a plain "docker build" produces this image.
FROM base AS final
USER $APP_UID

ARG APP_VERSION=local
ENV APP_VERSION=$APP_VERSION

COPY --from=build /app/publish .
ENTRYPOINT ["dotnet", "HelloAws.dll"]
