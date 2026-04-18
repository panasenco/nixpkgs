{
  config,
  lib,
  pkgs,
  ...
}:

with lib;

let
  cfg = config.services.crawlee-cloud;

  # Compose the DATABASE_URL from NixOS postgresql settings
  databaseUrl =
    if cfg.database.createLocally then
      "postgresql://${cfg.database.username}@localhost:5432/${cfg.database.database}?host=/run/postgresql"
    else
      cfg.database.url;

  # Compose the REDIS_URL
  redisUrl =
    if cfg.redis.createLocally then
      "redis://localhost:6379"
    else
      cfg.redis.url;

  dashboardDomain =
    if cfg.dashboardDomain != null then cfg.dashboardDomain
    else "dashboard.${cfg.domain}";

  # S3 endpoint: use local MinIO if enabled, otherwise the configured endpoint
  s3Endpoint =
    if cfg.minio.enable then
      "http://127.0.0.1:${toString cfg.minio.port}"
    else
      cfg.s3.endpoint;

  # Common environment variables shared across services
  commonEnv = {
    NODE_ENV = "production";
    DATABASE_URL = databaseUrl;
    REDIS_URL = redisUrl;
    S3_ENDPOINT = s3Endpoint;
    S3_BUCKET = cfg.s3.bucket;
    S3_REGION = cfg.s3.region;
    S3_FORCE_PATH_STYLE = if cfg.s3.forcePathStyle then "true" else "false";
    LOG_LEVEL = cfg.logLevel;
  };
in
{
  options = {
    services.crawlee-cloud = {
      enable = mkEnableOption "Crawlee Cloud platform";

      domain = mkOption {
        type = types.str;
        description = "Primary domain for the Crawlee Cloud API.";
        example = "crawlee.example.com";
      };

      dashboardDomain = mkOption {
        type = types.nullOr types.str;
        default = null;
        description = ''
          Domain for the Crawlee Cloud dashboard.
          Defaults to `dashboard.<domain>` if not set.
        '';
        example = "dashboard.crawlee.example.com";
      };

      apiPort = mkOption {
        type = types.port;
        default = 3000;
        description = "Port the API server listens on.";
      };

      dashboardPort = mkOption {
        type = types.port;
        default = 3001;
        description = "Port the dashboard listens on.";
      };

      logLevel = mkOption {
        type = types.enum [ "debug" "info" "warn" "error" ];
        default = "info";
        description = "Log level for Crawlee Cloud services.";
      };

      src = mkOption {
        type = types.path;
        description = ''
          Path to the crawlee-cloud source repository (pre-built).
        '';
      };

      secretsFile = mkOption {
        type = types.nullOr types.path;
        default = null;
        description = ''
          Path to an environment file containing secrets.
          Must define: API_SECRET, S3_ACCESS_KEY, S3_SECRET_KEY,
          ADMIN_EMAIL, ADMIN_PASSWORD.

          When minio.enable is true, must also define
          MINIO_ROOT_USER and MINIO_ROOT_PASSWORD.
        '';
      };

      runner = {
        maxConcurrentRuns = mkOption {
          type = types.int;
          default = 5;
          description = "Maximum number of concurrent actor runs.";
        };
      };

      database = {
        createLocally = mkOption {
          type = types.bool;
          default = true;
          description = "Create the PostgreSQL database and user locally.";
        };

        database = mkOption {
          type = types.str;
          default = "crawlee_cloud";
          description = "Name of the database.";
        };

        username = mkOption {
          type = types.str;
          default = "crawlee_cloud";
          description = "Username for database access.";
        };

        url = mkOption {
          type = types.nullOr types.str;
          default = null;
          description = "Full DATABASE_URL when not creating locally.";
        };
      };

      redis = {
        createLocally = mkOption {
          type = types.bool;
          default = true;
          description = "Create a local Redis instance.";
        };

        url = mkOption {
          type = types.nullOr types.str;
          default = null;
          description = "Full REDIS_URL when not creating locally.";
        };
      };

      s3 = {
        endpoint = mkOption {
          type = types.str;
          default = "";
          description = ''
            S3-compatible endpoint URL for external object storage.
            Ignored when minio.enable is true (uses local MinIO instead).
            Can be AWS S3, Cloudflare R2, OpenStack Swift s3api, etc.
          '';
          example = "https://s3.us-east-1.amazonaws.com";
        };

        bucket = mkOption {
          type = types.str;
          default = "crawlee-cloud";
          description = "S3 bucket name.";
        };

        region = mkOption {
          type = types.str;
          default = "us-east-1";
          description = "S3 region.";
        };

        forcePathStyle = mkOption {
          type = types.bool;
          default = false;
          description = ''
            Use path-style S3 URLs (endpoint/bucket) instead of virtual-hosted
            (bucket.endpoint). Required for MinIO and most non-AWS S3-compatible
            services. Automatically set to true when
            minio.enable is true.
          '';
        };
      };

      minio = {
        enable = mkOption {
          type = types.bool;
          default = false;
          description = ''
            Enable a local MinIO instance for S3-compatible storage.
            When enabled, s3.endpoint and s3.forcePathStyle are set automatically.
            The secretsFile must also define MINIO_ROOT_USER and MINIO_ROOT_PASSWORD.
          '';
        };

        port = mkOption {
          type = types.port;
          default = 9000;
          description = "MinIO S3 API port.";
        };

        consolePort = mkOption {
          type = types.port;
          default = 9001;
          description = "MinIO web console port.";
        };

        dataDir = mkOption {
          type = types.str;
          default = "/var/lib/minio/data";
          description = "MinIO data directory.";
        };
      };
    };
  };

  config = mkIf cfg.enable {
    assertions = [
      {
        assertion = cfg.database.createLocally || cfg.database.url != null;
        message = "services.crawlee-cloud.database.url must be set when createLocally is false.";
      }
      {
        assertion = cfg.redis.createLocally || cfg.redis.url != null;
        message = "services.crawlee-cloud.redis.url must be set when createLocally is false.";
      }
      {
        assertion = cfg.secretsFile != null;
        message = "services.crawlee-cloud.secretsFile must be set (must define API_SECRET, S3_ACCESS_KEY, S3_SECRET_KEY, ADMIN_EMAIL, ADMIN_PASSWORD).";
      }
      {
        assertion = cfg.minio.enable || cfg.s3.endpoint != "";
        message = "services.crawlee-cloud.s3.endpoint must be set when minio.enable is false.";
      }
    ];

    # ── PostgreSQL ───────────────────────────────────────────
    services.postgresql = mkIf cfg.database.createLocally {
      enable = true;
      ensureDatabases = [ cfg.database.database ];
      ensureUsers = [
        {
          name = cfg.database.username;
          ensureDBOwnership = true;
        }
      ];
    };

    # ── Redis ────────────────────────────────────────────────
    services.redis.servers.crawlee-cloud = mkIf cfg.redis.createLocally {
      enable = true;
      port = 6379;
    };

    # ── MinIO ────────────────────────────────────────────────
    services.minio = mkIf cfg.minio.enable {
      enable = true;
      listenAddress = "127.0.0.1:${toString cfg.minio.port}";
      consoleAddress = "127.0.0.1:${toString cfg.minio.consolePort}";
      dataDir = [ cfg.minio.dataDir ];
      rootCredentialsFile = cfg.secretsFile;
    };

    # Override S3 settings when MinIO is enabled
    services.crawlee-cloud.s3 = mkIf cfg.minio.enable {
      forcePathStyle = mkDefault true;
    };

    # ── Docker (needed for the runner to spawn actor containers) ──
    virtualisation.docker.enable = true;

    # ── System user ──────────────────────────────────────────
    users.users.crawlee-cloud = {
      isSystemUser = true;
      group = "crawlee-cloud";
      home = "/var/lib/crawlee-cloud";
      createHome = true;
      extraGroups = [ "docker" ];
    };
    users.groups.crawlee-cloud = { };

    # ── Crawlee Cloud API service ────────────────────────────
    systemd.services.crawlee-cloud-api = {
      description = "Crawlee Cloud API server";
      after = [ "network.target" "postgresql.service" "redis-crawlee-cloud.service" ]
        ++ optional cfg.minio.enable "minio.service";
      requires = [ "postgresql.service" "redis-crawlee-cloud.service" ]
        ++ optional cfg.minio.enable "minio.service";
      wantedBy = [ "multi-user.target" ];

      environment = commonEnv // {
        PORT = toString cfg.apiPort;
        CORS_ORIGINS = "https://${cfg.domain},https://${dashboardDomain}";
        RATE_LIMIT_MAX = "100";
      };

      serviceConfig = {
        Type = "simple";
        User = "crawlee-cloud";
        Group = "crawlee-cloud";
        WorkingDirectory = "${cfg.src}";
        ExecStartPre = "${pkgs.nodejs_20}/bin/npm ci --omit=dev --workspace=@crawlee-cloud/api --ignore-scripts";
        ExecStart = "${pkgs.nodejs_20}/bin/node packages/api/dist/index.js";
        Restart = "on-failure";
        RestartSec = 5;
        EnvironmentFile = mkIf (cfg.secretsFile != null) cfg.secretsFile;
        ProtectSystem = "full";
        PrivateTmp = true;
        NoNewPrivileges = true;
      };
    };

    # ── Crawlee Cloud Scheduler service ──────────────────────
    systemd.services.crawlee-cloud-scheduler = {
      description = "Crawlee Cloud Scheduler";
      after = [ "crawlee-cloud-api.service" ];
      requires = [ "crawlee-cloud-api.service" ];
      wantedBy = [ "multi-user.target" ];

      environment = commonEnv // {
        CORS_ORIGINS = "https://${cfg.domain},https://${dashboardDomain}";
      };

      serviceConfig = {
        Type = "simple";
        User = "crawlee-cloud";
        Group = "crawlee-cloud";
        WorkingDirectory = "${cfg.src}";
        ExecStart = "${pkgs.nodejs_20}/bin/node packages/api/dist/scheduler.js";
        Restart = "on-failure";
        RestartSec = 5;
        EnvironmentFile = mkIf (cfg.secretsFile != null) cfg.secretsFile;
        ProtectSystem = "full";
        PrivateTmp = true;
        NoNewPrivileges = true;
      };
    };

    # ── Crawlee Cloud Runner service ─────────────────────────
    systemd.services.crawlee-cloud-runner = {
      description = "Crawlee Cloud Runner";
      after = [ "crawlee-cloud-api.service" "docker.service" ];
      requires = [ "crawlee-cloud-api.service" "docker.service" ];
      wantedBy = [ "multi-user.target" ];

      environment = commonEnv // {
        API_BASE_URL = "http://127.0.0.1:${toString cfg.apiPort}";
        DOCKER_SOCKET = "/var/run/docker.sock";
        MAX_CONCURRENT_RUNS = toString cfg.runner.maxConcurrentRuns;
      };

      serviceConfig = {
        Type = "simple";
        User = "crawlee-cloud";
        Group = "crawlee-cloud";
        WorkingDirectory = "${cfg.src}";
        ExecStart = "${pkgs.nodejs_20}/bin/node packages/runner/dist/index.js";
        Restart = "on-failure";
        RestartSec = 5;
        EnvironmentFile = mkIf (cfg.secretsFile != null) cfg.secretsFile;
        SupplementaryGroups = [ "docker" ];
        ProtectSystem = "full";
        PrivateTmp = true;
      };
    };

    # ── Crawlee Cloud Dashboard service ──────────────────────
    systemd.services.crawlee-cloud-dashboard = {
      description = "Crawlee Cloud Dashboard";
      after = [ "crawlee-cloud-api.service" ];
      wantedBy = [ "multi-user.target" ];

      environment = {
        NODE_ENV = "production";
        PORT = toString cfg.dashboardPort;
        NEXT_PUBLIC_API_URL = "https://${cfg.domain}";
      };

      serviceConfig = {
        Type = "simple";
        User = "crawlee-cloud";
        Group = "crawlee-cloud";
        WorkingDirectory = "${cfg.src}";
        ExecStart = "${pkgs.nodejs_20}/bin/node packages/dashboard/server.js";
        Restart = "on-failure";
        RestartSec = 5;
        ProtectSystem = "full";
        PrivateTmp = true;
        NoNewPrivileges = true;
      };
    };

    # ── MinIO bucket initialization ──────────────────────────
    systemd.services.crawlee-cloud-minio-init = mkIf cfg.minio.enable {
      description = "Initialize Crawlee Cloud MinIO bucket";
      after = [ "minio.service" ];
      requires = [ "minio.service" ];
      wantedBy = [ "multi-user.target" ];

      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        EnvironmentFile = mkIf (cfg.secretsFile != null) cfg.secretsFile;
      };

      # Use minio-client (mc) to create the bucket
      path = [ pkgs.minio-client ];
      script = ''
        # Wait for MinIO to be ready
        for i in $(seq 1 30); do
          ${pkgs.curl}/bin/curl -sf http://127.0.0.1:${toString cfg.minio.port}/minio/health/live && break
          sleep 2
        done

        mc alias set local http://127.0.0.1:${toString cfg.minio.port} "$MINIO_ROOT_USER" "$MINIO_ROOT_PASSWORD"
        mc mb local/${cfg.s3.bucket} --ignore-existing
      '';
    };
  };

  meta.maintainers = [ ];
}
