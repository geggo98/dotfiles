# Gradle: Caching-Effekte beim Ändern von Builds ausschließen

Beim Ändern von Gradle-Builds immer mit `--no-build-cache` bauen, um
Caching-Effekte auszuschließen.

Für den Download von Artefakten das Caching mit einem frischen Home ausschließen,
etwa beim Erzeugen von Verification Metadata:

```bash
env GRADLE_USER_HOME=$(mktemp -d) ./gradlew --no-build-cache <task>
```
