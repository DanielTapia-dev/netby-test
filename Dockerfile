# ====== STAGE 1: Build ======
FROM maven:3.9.9-eclipse-temurin-21 AS build
WORKDIR /app

# Caché de dependencias
COPY pom.xml .
RUN mvn -B -q -DskipTests dependency:go-offline

# Código fuente
COPY src ./src

# Compilación (deja el nombre por defecto del jar)
RUN mvn -B -q -DskipTests clean package

# ====== STAGE 2: Runtime ======
FROM eclipse-temurin:21-jre
WORKDIR /app

# Copiamos el único .jar que hay en target (evita depender del nombre)
# (el .original lo ignora porque no coincide con *.jar si ajustas el patrón)
ARG JAR_FILE=/app/target/*-SNAPSHOT.jar
COPY --from=build ${JAR_FILE} /app/app.jar

# Usuario no-root
RUN useradd -r -u 1001 spring || true
USER spring

EXPOSE 8080
ENV JAVA_OPTS=""

ENTRYPOINT ["java","-jar","/app/app.jar"]
