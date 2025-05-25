# fly-deploy GitHub action

Supercharged fly-deploy GitHub Action. Deploys node.js applications to [fly.io](https://fly.io) with flexible configuration options.

## Inputs

| Name                  | Required | Description |
|-----------------------|----------|-------------|
| app_name_prefix       | No       | Prefix for the fly app name, useful for automatic app name generation. |
| app_name              | No       | Explicit name for the fly app. Overrides automatic name generation and prefix/suffix. |
| app_name_suffix       | No       | Suffix for the fly app name, useful for distinguishing environments. |
| config_file_path      | No       | Relative path to the fly config file. Defaults to `./fly.toml`. |
| secrets               | No       | Newline-separated list of secrets (`key=value`) to set on the fly app. |
| env_vars              | No       | Newline-separated list of non-secret environment variables (`key=value`) for the fly app. |
| build_args            | No       | Newline-separated list of build arguments (`key=value`) passed to docker build. |
| build_secrets         | No       | Newline-separated list of build-time secrets (`key=value`) available only during build. |
| workspace_name        | No       | Name of the workspace to deploy. Used to locate the workspace folder. |
| use_isolated_workspace| No       | Whether to set the working directory to the workspace path. Defaults to `false`. |
| attach_consul         | No       | Whether to attach a consul cluster to the app. Defaults to `false`. |
| private               | No       | Whether to enable flycast and only add a private IPv6 address. Defaults to `false`. |

## Outputs

| Name            | Description | Example |
|-----------------|-------------|---------|
| app_name        | The name of the deployed fly app. | forge42-base-stack-pr-42 |
| app_url         | The URL of the deployed fly app. | <https://forge42-base-stack-pr-42.fly.dev> |
| app_hostname    | The hostname of the deployed fly app. | forge42-base-stack-pr-42.fly.dev |
| app_id          | The ID of the deployed fly app. | forge42-base-stack-pr-42 |
| machine_names   | Names of the deployed machines. | bold-sound-1234,smart-eagle-4242 |
| machine_ids     | IDs of the deployed machines. | 3d42422df1234,3d42422df2345 |
| public_ips      | Public IPs of the app. | 2a09:8280:1::77:b341:0,66.241.1.1 |
| private_ips     | Private IPs of the app. | |
| workspace_name  | Name of the deployed workspace. | @forge42/base-stack |
| workspace_path  | Relative path of the deployed workspace. | . |

## Usage

### Minimal usage

```yaml
  deploy:
    name: 🚀 Deploy PR Preview
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: forge-42/fly-deploy@v1
        env:
          FLY_ORG: ${{ vars.FLY_ORG }}
          FLY_API_TOKEN: ${{ secrets.FLY_API_TOKEN }}
          FLY_REGION: ${{ vars.FLY_REGION }}
```

## Example using GitHub Environments for deploying dynamic PR Preview Environments

This example uses GitHub environments, which allow you to specify variables and secrets for each referenced environment (in this case, `pr-preview`). It also adds several non-secret environment variables to your fly app (`APP_ENV`, `LOG_LEVEL`, `FEATURE_FOO_ENABLED`) and one secret (`DATABASE_URL`).

```yaml
  deploy:
    name: 🚀 Deploy PR Preview
    runs-on: ubuntu-latest
    environment:
      name: pr-preview
      url: ${{ steps.deploy.outputs.app_url }}
    steps:
      - uses: actions/checkout@v4
      - uses: forge-42/fly-deploy@v1
        id: deploy
        env:
          FLY_ORG: ${{ vars.FLY_ORG }}
          FLY_API_TOKEN: ${{ secrets.FLY_API_TOKEN }}
          FLY_REGION: ${{ vars.FLY_REGION }}
        with:
          env_vars: |
            APP_ENV=staging
            LOG_LEVEL=debug
            FEATURE_FOO_ENABLED=false
          secrets: |
            DATABASE_URL=${{ secrets.DATABASE_URL }}
```

## Default build_args

The fly-deploy action adds several build arguments to your Docker build process by default. This is how the fly-deploy action attempts to retrieve values from:

- `APP_NAME`: The generated application name.
- `NODE_VERSION`: The value found in `.engines.node` in the package.json
- `PNPM_VERSION`: The value found in `.engines.pnpm` in the package.json
- `NPM_VERSION`: The value found in `.engines.npm` in the package.json
- `YARN_VERSION`: The value found in `.engines.yarn` in the package.json
- `TURBO_VERSION`: The value found in `.devDependencies.turbo` in the package.json
- `NX_VERSION`: The value found in `.dependencies.nx` in the package.json
- `WORKSPACE_NAME`: If configured as an input, it will be set to the input value. If not set, it will default to the value found in the `.name` field of the package.json file in the repository root.
- `WORKSPACE_PATH`: The relative path of the workspace for the package.json file, where the `.name` is set to `WORKSPACE_NAME`.
- `GIT_SHA`: Provides the long Git commit SHA. In a Pull-Request its the PR HEAD SHA.

### Example usage

```Dockerfile
# We specify a build argument in the Dockerfile and set a default fallback value if build-arg gets not set
# You dont need to update the Dockerfile with the correct version. The single source of truth is
# the version found in your package.json .engines.node field
ARG NODE_VERSION=22.14.0
FROM node:${NODE_VERSION}-alpine as dependencies

# Same for PNPM_VERSION, we specifiy the build arg and set a default fallback value.
# You dont need to update the Dockerfile with the correct version. The single source of truth is
# the version found in your package.json .engines.pnpm field
ARG PNPM_VERSION=10.8.0
RUN npm install -g pnpm@$PNPM_VERSION
```

#### Based on this package.json

```json
{
  "name": "@forge42/base-stack-example",
  "dependencies": {/*...*/},
  "devDependencies": {/*...*/},
  "engines": {
    "node": "22.14.0",
    "pnpm": "10.11.0"
  }
}
```

#### these build-args were generated and passed alongside the `fly deploy` command:

```sh
--build-arg NODE_VERSION=22.14.0 \
--build-arg PNPM_VERSION=10.11.0 \
--build-arg APP_NAME=forge42-base-stack-pr-42 \
--build-arg WORKSPACE_NAME=@forge42/base-stack \
--build-arg WORKSPACE_PATH=. \
--build-arg GIT_SHA=c38ab6bf587215ea93a2a134f2c82e20fb4e9108
```

## Roadmap

### v2.0.0

- Extract the node.js/package.json logic into separate actions. This will simplify the process of using outputs as inputs for `fly-deploy`.
