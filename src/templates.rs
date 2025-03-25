use crate::format_size;
use crate::Author;
use crate::{PKG_DESCRIPTION, PKG_NAME, PKG_VERSION};
use axum::response::{Html, IntoResponse, Response};

// 渲染文件列表页面
pub fn render_file_list(
    folders: Vec<(String, String, u64)>,
    files: Vec<(String, String, u64)>,
    current_path: Option<&str>,
    author: &Author,
) -> Response {
    // 生成面包屑导航
    let mut breadcrumbs_html = String::from(r#"<a href="/" class="text-sky-600 hover:text-sky-700 dark:text-sky-400">Home</a>"#);

    // 如果当前路径不是根目录，添加路径层级导航
    if let Some(path) = current_path {
        if path != "/" {
            // 分割路径并创建面包屑
            let mut current = String::new();
            let parts: Vec<&str> = path.split('/').filter(|p| !p.is_empty()).collect();

            for (idx, part) in parts.iter().enumerate() {
                current.push_str("/");
                current.push_str(part);

                let name = if idx == parts.len() - 1 {
                    // 最后一个部分，完整显示
                    part.to_string()
                } else {
                    if part.len() > 10 {
                        format!("{}...", &part[0..10])
                    } else {
                        part.to_string()
                    }
                };

                breadcrumbs_html
                    .push_str(&format!(r#" / <a href="/files{}" class="text-sky-600 hover:text-sky-700 dark:text-sky-400">{}</a>"#, current, name));
            }
        }
    }

    // 创建作者信息HTML
    let author_html = format!(
        r#"
        <div class="flex items-center space-x-4">
            <span class="text-slate-600 dark:text-slate-300">{}</span>
            {}
        </div>
        "#,
        author.name,
        author.github.as_ref().map_or(String::new(), |github| {
            format!(r#"<a href="{}" target="_blank" class="text-sky-600 hover:text-sky-700 dark:text-sky-400"><svg xmlns="http://www.w3.org/2000/svg" class="h-5 w-5 inline" viewBox="0 0 24 24" fill="currentColor"><path fill-rule="evenodd" clip-rule="evenodd" d="M12 2C6.477 2 2 6.477 2 12c0 4.42 2.865 8.164 6.839 9.489.5.092.682-.217.682-.482 0-.237-.008-.866-.013-1.7-2.782.603-3.369-1.341-3.369-1.341-.454-1.155-1.11-1.462-1.11-1.462-.908-.62.069-.608.069-.608 1.003.07 1.531 1.03 1.531 1.03.892 1.529 2.341 1.088 2.91.832.092-.647.35-1.088.636-1.338-2.22-.253-4.555-1.11-4.555-4.943 0-1.091.39-1.984 1.029-2.683-.103-.253-.446-1.27.098-2.647 0 0 .84-.269 2.75 1.025A9.578 9.578 0 0112 6.836c.85.004 1.705.114 2.504.336 1.909-1.294 2.747-1.025 2.747-1.025.546 1.377.202 2.394.1 2.647.64.699 1.028 1.592 1.028 2.683 0 3.842-2.339 4.687-4.566 4.935.359.309.678.919.678 1.852 0 1.336-.012 2.415-.012 2.743 0 .267.18.578.688.48C19.138 20.16 22 16.418 22 12c0-5.523-4.477-10-10-10z" /></svg></a>"#, github)
        })
    );

    let html = format!(
        r#"<!DOCTYPE html>
<html lang="zh-CN">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>{pkg_name} - {pkg_description}</title>
    <script src="https://cdn.tailwindcss.com"></script>
    <script>
        tailwind.config = {{
            darkMode: 'class',
            theme: {{
                extend: {{
                    colors: {{
                        primary: '#0284c7',
                    }}
                }}
            }}
        }}
    </script>
</head>
<body class="bg-slate-50 dark:bg-slate-900 text-slate-800 dark:text-slate-200">
    <div class="container mx-auto px-4 py-8 max-w-6xl">
        <header class="flex justify-between items-center mb-6 pb-4 border-b border-slate-200 dark:border-slate-700">
            <h1 class="text-2xl font-semibold text-primary">{pkg_name} <span class="text-xs align-top bg-slate-100 dark:bg-slate-700 px-2 py-1 rounded">{pkg_version}</span></h1>
            {author_html}
        </header>
        
        <div class="bg-white dark:bg-slate-800 rounded-xl shadow-md overflow-hidden border border-slate-100 dark:border-slate-700">
            <div class="px-6 py-3 bg-sky-50 dark:bg-slate-750 border-b border-slate-200 dark:border-slate-700 overflow-x-auto whitespace-nowrap">
                {breadcrumbs}
            </div>
            
            <div class="p-6">
                <div class="grid grid-cols-1 sm:grid-cols-2 md:grid-cols-3 lg:grid-cols-4 gap-4">
                    {folders_html}
                    {files_html}
                    {empty_html}
                </div>
            </div>
            
            <div class="px-6 py-3 bg-sky-50 dark:bg-slate-750 border-t border-slate-200 dark:border-slate-700 text-center text-sm text-slate-500 dark:text-slate-400">
                &copy; {copyright_year} {author_name} • {pkg_description}
            </div>
        </div>
    </div>
    
    <script>
        // 检测系统暗色模式并应用
        if (window.matchMedia && window.matchMedia('(prefers-color-scheme: dark)').matches) {{
            document.documentElement.classList.add('dark');
        }}
    </script>
</body>
</html>"#,
        author_html = author_html,
        breadcrumbs = breadcrumbs_html,
        folders_html = folders
            .iter()
            .map(|(name, path, _)| {
                format!(
                    r#"<a href="/files/{path}" class="flex items-center p-4 rounded-lg transition-colors hover:bg-sky-50 dark:hover:bg-slate-700/50 border border-transparent hover:border-sky-100 dark:hover:border-slate-600">
                        <div class="mr-3 text-amber-500 dark:text-amber-400 text-xl">📁</div>
                        <div class="flex-grow overflow-hidden">
                            <div class="truncate font-medium">{name}</div>
                            <div class="text-xs text-slate-500 dark:text-slate-400">目录</div>
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
                    _ => "📄",
                };

                format!(
                    r#"<a href="/files/{path}" class="flex items-center p-4 rounded-lg transition-colors hover:bg-sky-50 dark:hover:bg-slate-700/50 border border-transparent hover:border-sky-100 dark:hover:border-slate-600">
                        <div class="mr-3 text-sky-500 dark:text-sky-400 text-xl">{icon}</div>
                        <div class="flex-grow overflow-hidden">
                            <div class="truncate font-medium">{name}</div>
                            <div class="text-xs text-slate-500 dark:text-slate-400">{size_str}</div>
                        </div>
                    </a>"#
                )
            })
            .collect::<String>(),
        empty_html = if folders.is_empty() && files.is_empty() {
            r#"<div class="col-span-full py-12 text-center text-slate-500 dark:text-slate-400">此文件夹为空</div>"#
        } else {
            ""
        },
        copyright_year = chrono::Local::now().format("%Y"),
        author_name = author.name,
        pkg_name = PKG_NAME,
        pkg_version = PKG_VERSION,
        pkg_description = PKG_DESCRIPTION
    );

    Html(html).into_response()
}
