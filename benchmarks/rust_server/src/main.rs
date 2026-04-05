use actix_web::{web, App, HttpServer, HttpResponse, Responder};
use serde::Serialize;

async fn index() -> impl Responder {
    HttpResponse::Ok()
        .content_type("text/plain; charset=utf-8")
        .body("Welcome!")
}

async fn hello() -> impl Responder {
    HttpResponse::Ok()
        .content_type("text/plain; charset=utf-8")
        .body("Hello!")
}

#[derive(Serialize)]
struct JsonData {
    message: &'static str,
    status: &'static str,
}

async fn json_handler() -> impl Responder {
    let data = JsonData {
        message: "Hello, JSON!",
        status: "ok",
    };
    HttpResponse::Ok().json(data)
}

async fn get_user(path: web::Path<String>) -> impl Responder {
    let id = path.into_inner();
    HttpResponse::Ok()
        .content_type("text/plain; charset=utf-8")
        .body(format!("User: {}", id))
}

#[actix_web::main]
async fn main() -> std::io::Result<()> {
    let workers = std::thread::available_parallelism()
        .map(|n| n.get())
        .unwrap_or(4);

    println!("Actix-web starting on port 8081 with {} workers", workers);

    HttpServer::new(|| {
        App::new()
            .route("/", web::get().to(index))
            .route("/hello", web::get().to(hello))
            .route("/json", web::get().to(json_handler))
            .route("/user/{id}", web::get().to(get_user))
    })
    .bind("0.0.0.0:8081")?
    .workers(workers)
    .run()
    .await
}
