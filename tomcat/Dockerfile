# syntax=docker/dockerfile:1
ARG JAVA_VERSION=11

# ---------- Stage 1: build from the source cloned on the host ----------
FROM maven:3.9-eclipse-temurin-${JAVA_VERSION} AS build
ARG WAR_NAME=vprofile-v2.war
WORKDIR /src

COPY vprofile-project/pom.xml .
COPY vprofile-project/src ./src

# The cache mount keeps ~/.m2 between builds: dependencies download once,
# and the cache never ends up in the image
RUN --mount=type=cache,target=/root/.m2 \
    mvn -B -q package -DskipTests

RUN mkdir -p /out/ROOT && cd /out/ROOT && jar -xf "/src/target/$WAR_NAME" \
 && mv WEB-INF/classes/application.properties /out/application.properties.template
 
# ---------- Stage 2: runtime (Tomcat 9 + JRE only) ----------
FROM tomcat:9.0-jre${JAVA_VERSION}

# 4. non-root user, empty webapps, and an extra class path dir for the generated config
RUN groupadd --gid 10001 app \
 && useradd --uid 10001 --gid app --no-create-home --shell /usr/sbin/nologin app \
 && rm -rf /usr/local/tomcat/webapps/* \
 && mkdir -p /usr/local/tomcat/conf/Catalina/localhost /opt/app \
 && sed -i 's|^common.loader=.*|&,"/run/appconfig"|' /usr/local/tomcat/conf/catalina.properties

# 5. copy only the results from stage 1, plus the startup script
COPY --from=build /out/ROOT /usr/local/tomcat/webapps/ROOT
COPY --from=build /out/application.properties.template /opt/app/application.properties.template
COPY --chmod=755 entrypoint.sh /usr/local/bin/entrypoint.sh

# 6. run as the app user, document the port, add a health check
USER 10001:10001
EXPOSE 8080
HEALTHCHECK --interval=30s --timeout=5s --retries=3 --start-period=90s \
  CMD curl -fsS -o /dev/null http://localhost:8080/login || exit 1

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]