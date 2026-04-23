# 本地多 AK/SK 端到端环境

在本目录使用当前仓库的 `Dockerfile` 构建 lakeFS（OSS），并连接 PostgreSQL。

## 前置

- Docker 与 Docker Compose v2
- **Go 工具链**（脚本默认在仓库根执行 `go build -o ./lakectl ./cmd/lakectl`，生成与当前 API 一致的 `lakectl`）
- `curl`、`jq`、`perl`（首次 setup 用 curl+jq；perl 用于去色解析 lakectl 文本）
- 若设置 **`SKIP_LAKECTL_BUILD=1`**，则不会编译，此时须 **`export LAKECTL=/path/to/lakectl`** 指向已存在的二进制；否则脚本默认使用仓库根下的 `./lakectl` 且要求可执行。

## 启动

```bash
cd deployments/local-multi-ak-e2e
docker compose up -d --build
```

首次构建会包含 **前端 `npm run build`**（镜像内完成），比纯 Go 镜像更久，属正常情况。lakeFS 监听 `http://127.0.0.1:8000`（若 **8000** 被占用，可设置 `LAKEFS_HOST_PORT`，例如 `LAKEFS_HOST_PORT=18000 docker compose up -d`，并把下面 `LAKEFS_BASE_URL` 改成对应端口）。

PostgreSQL **默认不暴露到宿主机**，只供容器网络内的 lakeFS 使用，因此与本机是否占用 5433 等端口无关。若需要从本机连库调试，可执行：`docker compose exec postgres psql -U lakefs -d postgres`。

## 跑端到端脚本

```bash
export LAKEFS_BASE_URL=http://127.0.0.1:8000   # 若改了端口请同步修改
./e2e-multi-ak.sh
```

脚本开头会在仓库根 **自动 `go build` 生成 `lakectl`**（与 `go build -o ./lakectl ./cmd/lakectl` 一致），再跑用例。若要用系统里已有的 lakectl 且跳过编译：`SKIP_LAKECTL_BUILD=1 LAKECTL=$(command -v lakectl) ./e2e-multi-ak.sh`。

脚本会：curl 完成首次 `setup`；随后用 **lakectl** 做 `auth users credentials` 的 list/create/delete（含只读 AK）、`repo create` / `repo list` / `branch list`；最后验证吊销的 AK 无法再访问；结束时打印含完整密钥的**执行报告**（日志敏感，勿外传）。

## 清理

```bash
docker compose down -v
```

`-v` 删除卷，便于下次重新 setup。
