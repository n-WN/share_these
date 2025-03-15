use axum::{
    routing::get,
    Router,
    response::{Html, IntoResponse, Response},
    extract::{Path, ConnectInfo, State},
    http::StatusCode,
};
use std::{path::PathBuf, sync::Arc};
use tokio::fs;
use tracing::{info, error, Level};
use tracing_subscriber::FmtSubscriber;
use std::net::SocketAddr;
use tower_http::trace::TraceLayer;

mod templates;
use templates::render_file_list;

// 应用状态，存储根目录路径
#[derive(Clone)]
struct AppState {
    root_dir: Arc<PathBuf>,
}

#[tokio::main]
async fn main() -> Result<(), Box<dyn std::error::Error>> {
    // 初始化日志
    let subscriber = FmtSubscriber::builder()
        .with_max_level(Level::INFO)
        .with_target(false)
        .finish();
    tracing::subscriber::set_global_default(subscriber)?;

    // 获取工作目录作为根目录
    let root_dir = std::env::current_dir()?;
    let state = AppState {
        root_dir: Arc::new(root_dir),
    };

    // 构建应用程序
    let app = Router::new()
        .route("/", get(list_files))
        // 使用 {*path} 来捕获所有路径段，包括嵌套路径
        .route("/files/{*path}", get(serve_file))
        .layer(TraceLayer::new_for_http())
        .with_state(state);

    // 监听端口 3000
    let addr = "0.0.0.0:3000";
    let listener = tokio::net::TcpListener::bind(addr).await?;
    info!("Server running at http://localhost:3000");

    axum::serve(listener, app.into_make_service_with_connect_info::<SocketAddr>())
        .await?;

    Ok(())
}

// 列出当前目录下的文件和文件夹
async fn list_files(
    ConnectInfo(addr): ConnectInfo<SocketAddr>,
    State(state): State<AppState>,
) -> Response {
    let dir = &*state.root_dir;

    match fs::read_dir(dir).await {
        Ok(mut entries) => {
            let mut files = Vec::new();
            let mut folders = Vec::new();

            // 收集文件和文件夹信息
            while let Ok(Some(entry)) = entries.next_entry().await {
                if let Ok(metadata) = entry.metadata().await {
                    let path = entry.path();
                    let name = path.file_name()
                        .and_then(|n| n.to_str())
                        .unwrap_or("Unknown");

                    let relative_path = path.strip_prefix(dir)
                        .unwrap_or(&path)
                        .to_string_lossy();

                    // 区分文件和文件夹
                    if metadata.is_dir() {
                        folders.push((name.to_string(), relative_path.to_string(), 0));
                    } else {
                        files.push((name.to_string(), relative_path.to_string(), metadata.len()));
                    }
                }
            }

            // 按字母顺序排序
            folders.sort_by(|a, b| a.0.cmp(&b.0));
            files.sort_by(|a, b| a.0.cmp(&b.0));

            info!(ip = %addr.ip(), "File list requested for root directory");
            render_file_list(folders, files, Some("/"))
        },
        Err(e) => {
            error!(ip = %addr.ip(), "Failed to read directory: {}", e);
            Html(format!(
                r#"<html><body><h1>Error</h1><p>{}</p></body></html>"#,
                e
            )).into_response()
        }
    }
}

// 提供文件下载
async fn serve_file(
    Path(path): Path<String>,
    ConnectInfo(addr): ConnectInfo<SocketAddr>,
    State(state): State<AppState>,
) -> Response {
    let full_path = state.root_dir.join(&path);

    // 检查文件是否存在
    if !full_path.exists() {
        error!(ip = %addr.ip(), "File not found: {:?}", full_path);
        return StatusCode::NOT_FOUND.into_response();
    }

    // 如果是目录，则显示目录内容
    if full_path.is_dir() {
        match fs::read_dir(&full_path).await {
            Ok(mut entries) => {
                let mut files = Vec::new();
                let mut folders = Vec::new();

                // 收集文件和文件夹信息
                while let Ok(Some(entry)) = entries.next_entry().await {
                    if let Ok(metadata) = entry.metadata().await {
                        let entry_path = entry.path();
                        let name = entry_path.file_name()
                            .and_then(|n| n.to_str())
                            .unwrap_or("Unknown");

                        // 获取相对于根目录的路径
                        let relative_path = if let Ok(rel) = entry_path.strip_prefix(&*state.root_dir) {
                            rel.to_string_lossy().to_string()
                        } else {
                            // 如果无法相对于根目录，则使用相对于当前目录的路径
                            if let Some(rel) = entry_path.file_name() {
                                format!("{}/{}", path, rel.to_string_lossy())
                            } else {
                                name.to_string()
                            }
                        };

                        // 区分文件和文件夹
                        if metadata.is_dir() {
                            folders.push((name.to_string(), relative_path, 0));
                        } else {
                            files.push((name.to_string(), relative_path, metadata.len()));
                        }
                    }
                }

                // 按字母顺序排序
                folders.sort_by(|a, b| a.0.cmp(&b.0));
                files.sort_by(|a, b| a.0.cmp(&b.0));

                info!(ip = %addr.ip(), "Directory listing for: {}", path);
                render_file_list(folders, files, Some(&path))
            },
            Err(e) => {
                error!(ip = %addr.ip(), "Failed to read directory: {}", e);
                Html(format!(
                    r#"<html><body><h1>Error</h1><p>{}</p></body></html>"#,
                    e
                )).into_response()
            }
        }
    } else {
        // 读取文件内容
        match fs::read(&full_path).await {
            Ok(content) => {
                info!(ip = %addr.ip(), "File served: {:?}", full_path);

                // 简单的 MIME 类型检测
                let content_type = match full_path.extension().and_then(|e| e.to_str()) {
                    Some("html") | Some("htm") => "text/html",
                    Some("css") => "text/css",
                    Some("js") => "application/javascript",
                    Some("json") => "application/json",
                    Some("png") => "image/png",
                    Some("jpg") | Some("jpeg") => "image/jpeg",
                    Some("gif") => "image/gif",
                    Some("svg") => "image/svg+xml",
                    Some("pdf") => "application/pdf",
                    Some("txt") | Some("md") => "text/plain",
                    _ => "application/octet-stream",
                };

                ([(axum::http::header::CONTENT_TYPE, content_type)], content).into_response()
            },
            Err(e) => {
                error!(ip = %addr.ip(), "Failed to read file: {:?}, error: {}", full_path, e);
                StatusCode::INTERNAL_SERVER_ERROR.into_response()
            }
        }
    }
}

// 格式化文件大小
pub fn format_size(size: u64) -> String {
    const KB: u64 = 1024;
    const MB: u64 = KB * 1024;
    const GB: u64 = MB * 1024;

    if size < KB {
        format!("{} B", size)
    } else if size < MB {
        format!("{:.1} KB", size as f64 / KB as f64)
    } else if size < GB {
        format!("{:.1} MB", size as f64 / MB as f64)
    } else {
        format!("{:.1} GB", size as f64 / GB as f64)
    }
}