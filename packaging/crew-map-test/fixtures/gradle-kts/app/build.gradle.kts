plugins { id("org.springframework.boot") version "3.2.0" }
dependencies {
    implementation(project(":lib"))
    implementation(libs.okio)
    implementation("com.squareup.okhttp3:okhttp:4.12.0")
}
