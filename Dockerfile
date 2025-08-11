###############################
# Multi-stage Docker build for Spring Boot (Gradle) application
# Optimized for fast rebuilds & small runtime image
###############################

###############################
# 1. Base definitions (override with --build-arg as needed)
###############################
ARG JDK_IMAGE=eclipse-temurin:17-jdk
ARG JRE_IMAGE=eclipse-temurin:17-jre
ARG APP_NAME=buildah-demo
ARG APP_VERSION=0.0.1-SNAPSHOT
ARG JAR_FILE="${APP_NAME}-${APP_VERSION}.jar"

###############################
# 2. Build stage: compile the Spring Boot fat jar
###############################
FROM ${JDK_IMAGE} AS build
WORKDIR /app

# Leverage caching: copy only build metadata first
COPY gradlew gradlew
COPY gradle gradle
COPY build.gradle settings.gradle ./

# Pre-fetch dependencies (won't fail build if sources missing yet)
# (Removed BuildKit cache mount flag for buildah compatibility.)
RUN ./gradlew --no-daemon dependencyManagement || true

# Copy the source AFTER dependency download for better layer caching
COPY src src

# Build the executable jar (skip tests here for speed; remove -x test to include them)
# (Removed BuildKit cache mount flag.)
RUN ./gradlew --no-daemon clean bootJar -x test

###############################
# 3. Layer extraction stage for better runtime cache reuse
###############################
FROM ${JDK_IMAGE} AS layers
WORKDIR /layers
ARG JAR_FILE
COPY --from=build /app/build/libs/${JAR_FILE} app.jar
# Extract Boot layers: dependencies, snapshot-dependencies, spring-boot-loader, application
RUN java -Djarmode=layertools -jar app.jar extract

###############################
# 4. Minimal runtime stage
###############################
FROM ${JRE_IMAGE} AS runtime
WORKDIR /app

# Create and use non-root user
RUN useradd -u 1001 spring && mkdir -p /app && chown -R 1001:1001 /app
USER 1001

ARG APP_NAME
ARG JAR_FILE

ENV SPRING_PROFILES_ACTIVE=default \
    JAVA_OPTS="" \
    TZ=UTC

EXPOSE 8080

# Copy layers individually (smaller cache bust when only app code changes)
COPY --from=layers /layers/dependencies/ ./
COPY --from=layers /layers/snapshot-dependencies/ ./
COPY --from=layers /layers/spring-boot-loader/ ./
COPY --from=layers /layers/application/ ./

# Optional healthcheck (enable after adding actuator dependency)
# HEALTHCHECK --interval=30s --timeout=3s --start-period=30s --retries=3 CMD wget -q -O - http://127.0.0.1:8080/actuator/health || exit 1

# Launch using Spring Boot's layered JarLauncher
ENTRYPOINT ["sh","-c","java $JAVA_OPTS org.springframework.boot.loader.launch.JarLauncher"]
CMD [""]
