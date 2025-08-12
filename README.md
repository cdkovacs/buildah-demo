# Buildah Demo (Spring Boot + Gradle)

This repository demonstrates container image builds for a Spring Boot (Gradle) application using **Buildah** (via GitHub Actions) and contrasts Buildah with **Podman** and **Docker/BuildKit**. It also showcases two Dockerfile strategies and how caching works both inside a multi-stage build and at the CI workflow layer.

---
## 1. Quick Start

Build locally with Docker (optional):
```
docker build -t buildah-demo:latest .
docker run -p 8080:8080 buildah-demo:latest
```

GitHub Action automatically builds and pushes images to GHCR: `ghcr.io/<owner>/buildah-demo:<tag|version>`.

---
## 2. What is Buildah?
**Buildah** is a tool focused purely on building OCI/Docker container images without requiring a daemon. It works with an *open* local container storage (shared with Podman) and supports rootless builds.

### Buildah Key Points
- Daemonless (no background service like dockerd)
- Fine-grained control over image build steps (you can script instead of only using a Dockerfile)
- Shares storage with Podman; integrates well in rootless environments
- Native multi-arch (with QEMU/binfmt) when configured
- Emphasizes OCI standards

### Podman vs Buildah vs Docker/BuildKit
| Aspect | Buildah | Podman | Docker (BuildKit) |
|--------|---------|--------|-------------------|
| Primary Role | Building images | Running + building containers | Full platform: build + run (daemon) |
| Daemonless | Yes | Yes | No (dockerd daemon) |
| Rootless | Yes (first-class) | Yes (first-class) | Partial / evolving |
| Dockerfile Support | Yes | Yes | Yes |
| Scriptable Low-Level API | Yes (`buildah from`, `run`, `commit`) | Less granular | Limited (mainly Dockerfile) |
| Multi-Arch | Yes (with QEMU) | Yes (with QEMU) | Yes (Buildx) |
| Layer Cache | Local storage | Local storage | BuildKit advanced cache/export |
| Inline Cache Export | Manual / container storage | Same as Buildah | Built-in (cache mounts, export) |
| Compose Support | No | Yes (podman-compose) | Yes (docker compose) |

**When to pick Buildah:** security-focused CI, rootless pipelines, or when you need low-level control.  
**When to pick Podman:** day-to-day developer replacement for Docker CLI and runtime.  
**When to pick Docker/BuildKit:** broad ecosystem integration and advanced remote caching/export features.

---
## 3. Repository Layout Highlights
```
Dockerfile              # Multi-stage + Spring Boot layer extraction
Dockerfile.runtime      # Runtime-only (expects pre-built app.jar)
.github/workflows/build-push.yml  # Buildah-based CI workflow
build.gradle            # Gradle build config
```

---
## 4. The Two Dockerfiles
### 4.1 `Dockerfile` (Multi-Stage + Layered Spring Boot)
Goals:
- Build inside the container (no need for host JDK in CI step)
- Use Spring Boot layertools to split the fat jar into logical layers:
  - `dependencies/` (third-party immutable)
  - `snapshot-dependencies/` (changing SNAPSHOT libs)
  - `spring-boot-loader/` (launcher classes)
  - `application/` (your compiled code + resources)
- Leverages Docker layer cache: when only application code changes, only the `application/` COPY invalidates.

Key Steps:
1. Stage `build`: runs Gradle wrapper to compile and produce the jar.
2. Stage `layers`: runs `java -Djarmode=layertools -jar app.jar extract` reifying layers as directories.
3. Stage `runtime`: copies directories individually; uses `JarLauncher` to start.

Pros:
- Very fast rebuilds when code (not deps) changes.
- Single source of truth (no separate jar packaging step outside image build).

Cons:
- Build layer invalidates more often if you modify `build.gradle`.
- Without BuildKit cache mounts, Gradle dependency download repeats in clean CI runs (mitigated partially by Docker layer caching if the `gradle` & wrapper files remain unchanged).

### 4.2 `Dockerfile.runtime` (Runtime-Only Image)
Goals:
- Shift build work to the CI workflow (Gradle runs *before* image build).
- Create a minimal image stage that just copies an `app.jar`.

Pros:
- CI can leverage **actions/cache** for Gradle dependencies (faster & persistent across workflow runs).
- Simpler runtime image; smaller Docker build context changes.

Cons:
- Loses the fine-grained layer caching from Spring Boot layertools (jar is a single layer unless you adopt layering externally).
- Requires the workflow to reliably supply `app.jar`.

### Choosing Between Them
| Criterion | `Dockerfile` | `Dockerfile.runtime` |
|-----------|--------------|----------------------|
| Simplicity | Medium | High |
| Build Speed (warm Gradle cache) | Good | Excellent |
| Layer Granularity | High | Low |
| External Build Required | No | Yes |
| Best For | Frequent code changes, layered caching | Fast CI with external caching |

You can keep both: use multi-stage for local developer builds and runtime-only for CI speed, or vice versa.

---
## 5. GitHub Actions Workflow (`build-push.yml`)
Main Features:
1. Checks out code.
2. Sets up JDK 17 (with built-in Gradle dependency caching toggle AND explicit cache step for robustness).
3. Caches Gradle wrapper + dependency caches using `actions/cache` (keyed by hash of Gradle scripts + wrapper properties).
4. Derives application version from `build.gradle` (or tag on release builds).
5. Builds the JAR (`./gradlew clean bootJar -x test`).
6. Prepares `app.jar` at repository root.
7. Sets up QEMU for multi-arch (arm64 + amd64) emulation.
8. Uses `redhat-actions/buildah-build` to build a runtime image (`Dockerfile.runtime`).
9. Pushes image & tags (latest + semantic version) to GHCR.

### Why Cache at the Workflow Layer?
Container-layer caching in CI can be cold if the runner is ephemeral. Workflow-level caching:
- Rehydrates `~/.gradle/caches` quickly before the image build.
- Avoids re-downloading dependencies inside the container each run.
- Keeps image build narrow: only copying `app.jar` triggers minimal invalidation.

### Multi-Arch Build Notes
- QEMU setup is necessary on an amd64 runner to build arm64 image layers.
- Buildah creates a manifest list combining architectures.

---
## 6. Caching Deep Dive
| Layer | Mechanism | Where | Notes |
|-------|-----------|-------|-------|
| Gradle Dependencies | `actions/cache` + setup-java cache | Workflow | Survives across runs; fastest reuse |
| Docker Layers (multi-stage) | COPY/build boundaries | Docker/Buildah storage | Only when using `Dockerfile` variant |
| Spring Boot Layers | `layertools extract` | File system before final stage | Provides granular dependency vs app code separation |
| Runtime Jar (runtime Dockerfile) | Single COPY | Final image | Simple but coarse: any code change invalidates layer |


---
## 7. Switching Strategies
To revert CI to the multi-stage layered Dockerfile:
1. Change the `containerfiles:` entry back to `./Dockerfile`.
2. Remove the external `Build JAR` + `Prepare app.jar` steps.
3. (Optional) Add a Gradle cache warm-up step before Buildah to accelerate the in-container build by copying `.gradle` (requires adjusting Dockerfile to COPY it conditionally—trade-offs apply).

---
## 8. Local Development
Using the multi-stage Dockerfile is simplest locally:
```
docker build -t buildah-demo:layered .
docker run -p 8080:8080 buildah-demo:layered
```
If you prefer the runtime variant locally:
```
./gradlew clean bootJar -x test
cp build/libs/*.jar app.jar
docker build -f Dockerfile.runtime -t buildah-demo:runtime .
docker run -p 8080:8080 buildah-demo:runtime
```

---
## 9. Logging
Lombok `@Slf4j` was added to the main application class to log startup events. Adjust `JAVA_OPTS` in runtime to configure logging further (e.g., `-Dlogging.level.root=INFO`).

---
## 10. Troubleshooting
| Issue | Cause | Fix |
|-------|-------|-----|
| Slow CI build | Cold Gradle deps | Ensure cache key stable; avoid unnecessary `clean` when not needed |
| Large image size | Layered jar still heavy | Consider distroless or jlink custom runtime image |
| Healthcheck fails | Actuator not present | Add `spring-boot-starter-actuator` and uncomment HEALTHCHECK |

---
## 11. Next Steps
- Add release tagging job on Git tags (semantic version parse)
- Add SBOM (Syft) and signing (Cosign)
- Integrate test and coverage gates pre-image build
- Enable dependabot or renovate for dependency updates

---
## 12. References
- Buildah: https://github.com/containers/buildah
- Podman: https://podman.io/
- Spring Boot Layered Jars: https://docs.spring.io/spring-boot/reference/docker/layers.html
- Buildah GitHub Action: https://github.com/redhat-actions/buildah-build
- GHCR Docs: https://docs.github.com/en/packages