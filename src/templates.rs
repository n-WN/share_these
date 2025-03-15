use axum::{
    response::{Html, IntoResponse, Response}
};
use crate::format_size;

// 渲染文件列表页面
pub fn render_file_list(folders: Vec<(String, String, u64)>, files: Vec<(String, String, u64)>, current_path: Option<&str>) -> Response {
    // 生成面包屑导航
    // https://developer.mozilla.org/zh-CN/docs/Glossary/Breadcrumb
    let mut breadcrumbs_html = String::from(r#"<a href="/">Home</a>"#);

    // 如果当前路径不是根目录，添加路径层级导航
    if let Some(path) = current_path {
        if path != "/" {
            // 分割路径并创建面包屑
            let mut current = String::new();
            let parts: Vec<&str> = path.split('/').filter(|p| !p.is_empty()).collect();

            for (idx, part) in parts.iter().enumerate() {
                current.push_str("/");
                current.push_str(part);

                let name = if idx == parts.len() - 1 { // 最后一个部分，完整显示
                    part.to_string()
                } else {
                    if part.len() > 10 {
                        format!("{}...", &part[0..10])
                    } else {
                        part.to_string()
                    }
                };

                breadcrumbs_html.push_str(&format!(r#" / <a href="/files{}">{}</a>"#, current, name));
            }
        }
    }

    let html = format!(
        r#"<!DOCTYPE html>
<html lang="zh-CN">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>File Server</title>
    <style>
        :root {{
            --bg-color: #f8f9fa;
            --card-bg: white;
            --text-color: #333;
            --accent: #4a6eb5;
            --hover: #e9f0ff;
            --border: #eaeaea;
        }}
        * {{ box-sizing: border-box; margin: 0; padding: 0; }}
        body {{
            font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, Arial, sans-serif;
            background: var(--bg-color);
            color: var(--text-color);
            line-height: 1.6;
            padding: 20px;
            max-width: 1200px;
            margin: 0 auto;
        }}
        h1 {{
            font-size: 24px;
            font-weight: 500;
            margin-bottom: 20px;
            padding-bottom: 10px;
            border-bottom: 1px solid var(--border);
        }}
        .container {{
            background: var(--card-bg);
            border-radius: 8px;
            box-shadow: 0 2px 8px rgba(0,0,0,0.05);
            overflow: hidden;
        }}
        .file-list {{
            display: grid;
            grid-template-columns: repeat(auto-fill, minmax(250px, 1fr));
            gap: 4px;
            padding: 16px;
        }}
        .file-item {{
            display: flex;
            align-items: center;
            padding: 10px 15px;
            border-radius: 6px;
            transition: all 0.2s;
        }}
        .file-item:hover {{
            background: var(--hover);
        }}
        .icon {{
            margin-right: 10px;
            font-size: 20px;
            color: var(--accent);
            width: 24px;
            text-align: center;
        }}
        .folder-icon {{ color: #e9bc4f; }}
        .details {{
            flex-grow: 1;
            overflow: hidden;
        }}
        .name {{
            white-space: nowrap;
            overflow: hidden;
            text-overflow: ellipsis;
        }}
        .size {{
            font-size: 12px;
            color: #777;
        }}
        a {{
            text-decoration: none;
            color: inherit;
            display: block;
            width: 100%;
        }}
        .breadcrumb {{
            padding: 10px 20px;
            background: var(--card-bg);
            border-bottom: 1px solid var(--border);
            white-space: nowrap;
            overflow-x: auto;
        }}
        .breadcrumb a {{
            color: var(--accent);
            display: inline;
        }}
        .empty {{
            padding: 30px;
            text-align: center;
            color: #777;
        }}
    </style>
</head>
<body>
    <h1>File Server</h1>
    <div class="container">
        <div class="breadcrumb">
            {breadcrumbs}
        </div>
        <div class="file-list">
            {folders_html}
            {files_html}
            {empty_html}
        </div>
    </div>
</body>
</html>"#,
        breadcrumbs = breadcrumbs_html,
        folders_html = folders
            .iter()
            .map(|(name, path, _)| {
                format!(
                    r#"<a href="/files/{path}" class="file-item">
                        <div class="icon folder-icon">📁</div>
                        <div class="details">
                            <div class="name">{name}</div>
                            <div class="size">Directory</div>
                        </div>
                    </a>"#
                )
            })
            .collect::<String>(),
        files_html = files
            .iter()
            .map(|(name, path, size)| {
                // 格式化文件大小
                let size_str = format_size(*size);

                // 文件图标选择
                let icon = match name.split('.').last().unwrap_or("") {
                    "pdf" => "📄",
                    "doc" | "docx" => "📝",
                    "xls" | "xlsx" => "📊",
                    "ppt" | "pptx" => "📑",
                    "jpg" | "jpeg" | "png" | "gif" | "bmp" | "svg" => "🖼️",
                    "mp3" | "wav" | "ogg" | "flac" => "🎵",
                    "mp4" | "avi" | "mov" | "wmv" | "mkv" => "🎬",
                    "zip" | "rar" | "7z" | "tar" | "gz" => "🗜️",
                    "exe" | "msi" | "app" => "⚙️",
                    "html" | "htm" => "🌐",
                    "css" => "🎨",
                    "js" | "ts" => "📜",
                    "rs" | "go" | "py" | "java" | "c" | "cpp" | "cs" => "💻",
                    "md" | "txt" => "📃",
                    "json" | "xml" | "yaml" | "yml" => "🔧",
                    "git" | "gitignore" => "📦",
                    "apk" => "📱",
                    "iso" => "💿",
                    "torrent" => "🧲",
                    "bak" | "old" | "temp" => "🗑️",
                    _ => "📄"
                };

                format!(
                    r#"<a href="/files/{path}" class="file-item">
                        <div class="icon">{icon}</div>
                        <div class="details">
                            <div class="name">{name}</div>
                            <div class="size">{size_str}</div>
                        </div>
                    </a>"#
                )
            })
            .collect::<String>(),
        empty_html = if folders.is_empty() && files.is_empty() {
            r#"<div class="empty">此文件夹为空</div>"#
        } else {
            ""
        }
    );

    Html(html).into_response()
}