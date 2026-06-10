// worker/index.js
export default {
    async fetch(request, env, _ctx) {
        const url = new URL(request.url);
        const pathname = url.pathname;
        const GITHUB_REPO = env.GITHUB_REPO || 'hestiacn/hestiacp-freebsd';
        const GITHUB_TAG  = env.GITHUB_TAG  || 'release';
        const GITHUB_BASE = `https://github.com/${GITHUB_REPO}/releases/download/${GITHUB_TAG}`;
        const R2_BUCKET   = env.R2_BUCKET || 'fbsd-repo';
        const R2_ENDPOINT = env.R2_ENDPOINT || '';
        const MIRROR_BASE = env.MIRROR_BASE || '';
        
        if (pathname === '/' || pathname === '/health') {
            const homeHtml = `
<!DOCTYPE html>
<html lang="zh-CN">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>HestiaCP FreeBSD 软件源</title>
    <link rel="icon" type="image/x-icon" href="https://hestiacp.com/favicon.ico">
    <link rel="shortcut icon" href="https://hestiacp.com/favicon.ico">
    <link rel="apple-touch-icon" href="https://hestiacp.com/apple-touch-icon.png">
    <link rel="icon" type="image/png" sizes="192x192" href="https://hestiacp.com/icon-192.png">
    <link rel="icon" type="image/png" sizes="512x512" href="https://hestiacp.com/icon-512.png">
    <style>
        * {
            margin: 0;
            padding: 0;
            box-sizing: border-box;
            transition: background-color 0.2s ease, color 0.2s ease, border-color 0.2s ease;
        }

        :root {
            --bg-body: #f5f7fb;
            --bg-card: #ffffff;
            --border-card: #e2e8f0;
            --text-primary: #1e293b;
            --text-secondary: #475569;
            --accent-color: #10b981;
            --accent-soft: rgba(16, 185, 129, 0.1);
            --accent-border: rgba(16, 185, 129, 0.25);
            --badge-bg: #f2f2f2;
            --badge-text: #047857;
            --footer-border: #e2e8f0;
            --footer-text: #5b6e8c;
            --footer-link: #3b82f6;
            --footer-link-hover: #10b981;
            --shadow-card: 0 10px 30px rgba(0, 0, 0, 0.05);
            --btn-bg: #f1f5f9;
            --btn-hover: #e2e8f0;
            --btn-text: #1e293b;
        }

        body.dark {
            --bg-body: #09090b;
            --bg-card: #18181b;
            --border-card: #27272a;
            --text-primary: #f4f4f5;
            --text-secondary: #d4d4d8;
            --accent-color: #10b981;
            --accent-soft: rgba(16, 185, 129, 0.12);
            --accent-border: rgba(16, 185, 129, 0.25);
            --badge-bg: rgba(16, 185, 129, 0.12);
            --badge-text: #34d399;
            --footer-border: #27272a;
            --footer-text: #71717a;
            --footer-link: #60a5fa;
            --footer-link-hover: #34d399;
            --shadow-card: 0 10px 30px rgba(0, 0, 0, 0.5);
            --btn-bg: #27272a;
            --btn-hover: #3f3f46;
            --btn-text: #f4f4f5;
        }

        body {
            font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, "Helvetica Neue", sans-serif;
            background-color: var(--bg-body);
            color: var(--text-primary);
            display: flex;
            align-items: center;
            justify-content: center;
            min-height: 100vh;
            margin: 0;
            padding: 20px;
        }

        .card {
            max-width: 680px;
            width: 100%;
            background: var(--bg-card);
            padding: 2rem;
            border: 1px solid var(--border-card);
            border-radius: 28px;
            text-align: center;
            box-shadow: var(--shadow-card);
            position: relative;
        }

        .toolbar {
            position: absolute;
            top: 20px;
            right: 24px;
            display: flex;
            gap: 10px;
            z-index: 10;
        }

        .theme-toggle, .lang-toggle {
            background: var(--btn-bg);
            border: 1px solid var(--border-card);
            border-radius: 40px;
            padding: 6px 14px;
            font-size: 0.8rem;
            font-weight: 500;
            cursor: pointer;
            display: inline-flex;
            align-items: center;
            gap: 6px;
            color: var(--btn-text);
            transition: all 0.2s;
            backdrop-filter: blur(4px);
        }

        .theme-toggle:hover, .lang-toggle:hover {
            background: var(--btn-hover);
            transform: translateY(-1px);
        }

        .brand-logo {
            display: block;
            width: auto;
            height: 150px;
            max-width: 80%;
            margin: 10px auto 20px;
            object-fit: contain;
        }
        
        .badge {
            display: inline-block;
            background: var(--badge-bg);
            color: var(--badge-text);
            padding: 4px 14px;
            border-radius: 9999px;
            font-size: 0.75rem;
            font-weight: 600;
            margin-bottom: 20px;
            border: 1px solid var(--accent-border);
        }

        h1 {
            color: var(--accent-color);
            font-size: 2rem;
            margin-bottom: 20px;
            font-weight: 700;
            letter-spacing: -0.02em;
        }

        .notice-text {
            font-size: 0.95rem;
            line-height: 1.7;
            color: var(--text-secondary);
            margin: 20px 0;
            text-align: left;
            background-color: var(--bg-body);
            padding: 15px 20px;
            border-radius: 12px;
            border-left: 4px solid var(--accent-color);
        }

        .deploy-btn {
            display: inline-block;
            background-color: #10b981;
            color: white !important;
            font-weight: 600;
            padding: 10px 28px;
            border-radius: 40px;
            text-decoration: none;
            transition: all 0.2s ease;
            border: none;
            cursor: pointer;
            box-shadow: 0 2px 5px rgba(16, 185, 129, 0.2);
            margin-top: 10px;
        }

        .deploy-btn:hover {
            background-color: #059669;
            transform: translateY(-2px);
            box-shadow: 0 5px 15px rgba(16, 185, 129, 0.3);
            text-decoration: none;
        }

        .deploy-btn:active {
            transform: translateY(1px);
        }

        footer {
            margin-top: 35px;
            padding-top: 25px;
            border-top: 1px solid var(--footer-border);
            font-size: 0.8rem;
            color: var(--footer-text);
            line-height: 1.8;
        }

        footer a {
            color: var(--footer-link);
            text-decoration: none;
            font-weight: 500;
        }

        footer a:hover {
            color: var(--footer-link-hover);
            text-decoration: underline;
        }

        .footer-line {
            display: flex;
            align-items: center;
            justify-content: center;
            flex-wrap: wrap;
            gap: 6px;
            margin-bottom: 10px;
        }

        .badge-img {
            display: inline-block !important;
            height: 20px;
            margin: -2px 0 0 5px;
            vertical-align: middle;
            border-radius: 4px;
        }

        .hidden-lang {
            display: none;
        }

        .sep {
            color: var(--border-card);
            margin: 0 4px;
        }

        @media (max-width: 520px) {
            .card { padding: 1.5rem; }
            h1 { font-size: 1.7rem; }
            .brand-logo { height: 100px; }
            .toolbar { top: 12px; right: 16px; gap: 6px; }
            .theme-toggle, .lang-toggle { padding: 4px 10px; font-size: 0.7rem; }
            .deploy-btn { padding: 8px 20px; font-size: 0.85rem; }
        }
    </style>
</head>
<body>
<div class="card">
    <div class="toolbar">
        <button class="theme-toggle" id="themeToggleBtn" aria-label="Switch theme">
            <span id="themeIcon">🌙</span> 
            <span id="themeText">深色模式</span>
        </button>
        <button class="lang-toggle" id="langToggleBtn" aria-label="Switch language">
            <span id="langIcon">🇨🇳</span> 
            <span id="langText">中文</span>
        </button>
    </div>

    <img src="https://hestiacp.com/logo.svg" alt="HestiaCP Logo" class="brand-logo" referrerpolicy="no-referrer" onerror="this.style.display='none'">

    <div id="enContent" class="lang-block hidden-lang">
        <h1>HestiaCP FreeBSD Repository</h1>
        <div class="notice-text">
            <strong>🛡️</strong> This is a <strong>dedicated package repository for FreeBSD server management infrastructure</strong>, providing cryptographically signed RSA validation for the HestiaCP panel ecosystem.
        </div>
        <div class="notice-text">
            <strong>📢</strong> This repository is exclusively designed for integration with the FreeBSD <code>pkg</code> package manager. It is <strong>not a general-purpose software mirror</strong>. Public package search or anonymous downloads are not supported.
        </div>
        <div class="link-main">
            <a href="https://hestiamb.org/Freebsd" target="_blank" class="deploy-btn">Deployment Guide →</a>
        </div>
    </div>

    <div id="zhContent" class="lang-block">
        <h1>HestiaCP FreeBSD 软件源</h1>
        <div class="notice-text">
            <strong>🛡️</strong> 本站是 <strong>FreeBSD 服务器管理软件基础设施专用包仓库</strong>，为 HestiaCP 面板生态系统提供 RSA 密钥数字签名验证支持。
        </div>
        <div class="notice-text">
            <strong>📢</strong> 本仓库专为 FreeBSD <code>pkg</code> 包管理器集成而设计，<strong>非通用软件镜像站</strong>，不提供公开的软件包检索或匿名下载服务。
        </div>
        <div class="link-main">
            <a href="https://hestiamb.org/Freebsd" target="_blank" class="deploy-btn">部署指南</a>
        </div>
    </div>

    <footer>
        <div class="footer-line">
            <span id="licenseText">根据</span> 
            <a id="licenseLink" href="https://gitee.com/mirrors_hestiacp/hestiacp/raw/main/LICENSE" target="_blank">
                <img src="https://img.shields.io/badge/License-GPLv3-red.svg?labelColor=b7236a" alt="GPLv3" class="badge-img">
            </a>
            <span class="sep">|</span>
            <a href="https://http3.wcode.net/?q=pkg.hestiamb.org" target="_blank" id="httpBadgeLink">
                <img id="httpBadge" src="https://img.shields.io/badge/https-%E6%9C%AC%E7%AB%99%E6%94%AF%E6%8C%81HTTP3-2ECC71?labelColor=b7236a" alt="HTTP/3" class="badge-img">
            </a>
        </div>
        <div class="footer-line">
            <span id="copyrightPrefix">版权所有 © 2019 -</span>
            <span id="dynamicYear"></span>
            <a href="https://hestiacp.com" target="_blank" id="hestiaBadgeLink">
                <img id="hestiaBadge" src="https://img.shields.io/badge/Hestia-%E6%9C%8D%E5%8A%A1%E5%99%A8%E6%8E%A7%E5%88%B6%E9%9D%A2%E6%9D%BF-006BFF?labelColor=b7236a" alt="Hestia" class="badge-img">
            </a>
        </div>
    </footer>
</div>

<script>
    (function() {
        const themeToggleBtn = document.getElementById('themeToggleBtn');
        const themeIconSpan = document.getElementById('themeIcon');
        const themeTextSpan = document.getElementById('themeText');
        const themeTextMap = {
            switchToLight_zh: '浅色模式',
            switchToDark_zh: '深色模式',
            switchToLight_en: 'Light Mode',
            switchToDark_en: 'Dark Mode'
        };
        
        const getStoredTheme = () => localStorage.getItem('theme');
        const setStoredTheme = (theme) => localStorage.setItem('theme', theme);
        const getStoredLang = () => localStorage.getItem('lang') || 'zh';
        const updateThemeButtonText = () => {
            const currentLang = getStoredLang();
            const isDark = document.body.classList.contains('dark');
            if (isDark) {
                themeTextSpan.innerText = currentLang === 'zh' ? themeTextMap.switchToLight_zh : themeTextMap.switchToLight_en;
                themeIconSpan.innerText = '☀️';
            } else {
                themeTextSpan.innerText = currentLang === 'zh' ? themeTextMap.switchToDark_zh : themeTextMap.switchToDark_en;
                themeIconSpan.innerText = '🌙';
            }
        };
        
        const applyTheme = (theme) => {
            const isDark = theme === 'dark';
            if (isDark) {
                document.body.classList.add('dark');
                document.documentElement.setAttribute('data-theme', 'dark');
            } else {
                document.body.classList.remove('dark');
                document.documentElement.removeAttribute('data-theme');
            }
            updateThemeButtonText();
        };
        
        const toggleTheme = () => {
            const isDarkNow = document.body.classList.contains('dark');
            const newTheme = isDarkNow ? 'light' : 'dark';
            applyTheme(newTheme);
            setStoredTheme(newTheme);
        };
        
        const initTheme = () => {
            const stored = getStoredTheme();
            if (stored === 'dark' || stored === 'light') {
                applyTheme(stored);
            } else {
                const prefersDark = window.matchMedia('(prefers-color-scheme: dark)').matches;
                applyTheme(prefersDark ? 'dark' : 'light');
            }
        };
        
        if (themeToggleBtn) themeToggleBtn.addEventListener('click', toggleTheme);
        initTheme();
        const enContentDiv = document.getElementById('enContent');
        const zhContentDiv = document.getElementById('zhContent');
        const langToggleBtn = document.getElementById('langToggleBtn');
        const langIconSpan = document.getElementById('langIcon');
        const langTextSpan = document.getElementById('langText');
        
        const hestiaBadge = document.getElementById('hestiaBadge');
        const httpBadge = document.getElementById('httpBadge');
        const licenseSpan = document.getElementById('licenseText');
        const licenseLink = document.getElementById('licenseLink');
        const copyrightPrefixSpan = document.getElementById('copyrightPrefix');
        const licenseEn = "Licensed under";
        const licenseZh = "根据";
        const copyrightPrefixEn = "Copyright © 2019 -";
        const copyrightPrefixZh = "版权所有 © 2019 -";
        const licenseUrlZh = "https://gitee.com/mirrors_hestiacp/hestiacp/raw/main/LICENSE";
        const licenseUrlEn = "https://raw.githubusercontent.com/hestiacp/hestiacp/main/LICENSE";
        const hestiaBadgeZh = "https://img.shields.io/badge/Hestia-%E6%9C%8D%E5%8A%A1%E5%99%A8%E6%8E%A7%E5%88%B6%E9%9D%A2%E6%9D%BF-006BFF?labelColor=b7236a";
        const hestiaBadgeEn = "https://img.shields.io/badge/Hestia-Open%20source%20web%20server%20control%20panel-006BFF?labelColor=b7236a";
        const httpBadgeZh = "https://img.shields.io/badge/https-%E6%9C%AC%E7%AB%99%E6%94%AF%E6%8C%81HTTP3-2ECC71?labelColor=b7236a";
        const httpBadgeEn = "https://img.shields.io/badge/https-HTTP/3%20supported-2ECC71?labelColor=b7236a";
        const setStoredLang = (lang) => localStorage.setItem('lang', lang);
        const applyLanguage = (lang) => {
            setStoredLang(lang);
            const isZh = (lang === 'zh');
            if (enContentDiv && zhContentDiv) {
                if (isZh) {
                    enContentDiv.classList.add('hidden-lang');
                    zhContentDiv.classList.remove('hidden-lang');
                } else {
                    zhContentDiv.classList.add('hidden-lang');
                    enContentDiv.classList.remove('hidden-lang');
                }
            }
            
            if (langIconSpan) langIconSpan.innerText = isZh ? '🇨🇳' : '🇺🇸';
            if (langTextSpan) langTextSpan.innerText = isZh ? '中文' : 'English';
            if (licenseSpan) licenseSpan.innerText = isZh ? licenseZh : licenseEn;
            if (copyrightPrefixSpan) copyrightPrefixSpan.innerText = isZh ? copyrightPrefixZh : copyrightPrefixEn;
            if (licenseLink) licenseLink.href = isZh ? licenseUrlZh : licenseUrlEn;
            if (hestiaBadge) hestiaBadge.src = isZh ? hestiaBadgeZh : hestiaBadgeEn;
            if (httpBadge) httpBadge.src = isZh ? httpBadgeZh : httpBadgeEn;
            document.title = isZh ? "HestiaCP FreeBSD 软件源" : "HestiaCP FreeBSD Package Repository";
            updateThemeButtonText();
        };
        
        const toggleLanguage = () => {
            const currentLang = getStoredLang();
            const newLang = currentLang === 'zh' ? 'en' : 'zh';
            applyLanguage(newLang);
        };
        
        if (langToggleBtn) langToggleBtn.addEventListener('click', toggleLanguage);
        
        const initLang = () => {
            const storedLang = getStoredLang();
            applyLanguage(storedLang);
        };
        initLang();
        
        window.matchMedia('(prefers-color-scheme: dark)').addEventListener('change', (e) => {
            if (!localStorage.getItem('theme')) {
                applyTheme(e.matches ? 'dark' : 'light');
            }
        });
        
        function updateYear() {
            const yearEl = document.getElementById('dynamicYear');
            if (yearEl) {
                const year = new Date().getFullYear();
                if (yearEl.textContent !== year.toString()) {
                    yearEl.textContent = year;
                }
            }
        }
        document.readyState === 'loading' ? document.addEventListener('DOMContentLoaded', updateYear) : updateYear();
        setInterval(updateYear, 3600000);
        document.querySelectorAll('button').forEach(btn => btn.setAttribute('tabindex', '0'));
    })();
</script>
</body>
</html>
            `;
            return new Response(homeHtml, {
                status: 200,
                headers: {
                    'Content-Type': 'text/html; charset=utf-8',
                    'Cache-Control': 'public, max-age=3600',
                    'X-Content-Type-Options': 'nosniff'
                }
            });
        }
        
        // 动态渲染并下发 100% 契合 R2 静态规范的一键配置客户端自愈脚本
        if (pathname === '/setup-client.sh') {
            const clientScript = getClientSetupScript(url.origin);
            return new Response(clientScript, {
                status: 200,
                headers: {
                    'Content-Type': 'text/plain; charset=utf-8',
                    'Cache-Control': 'public, max-age=3600'
                }
            });
        }
        
        // RSA 安全公钥动态透传下载
        if (pathname === '/hestiacp.pub') {
            const pubKey = env.HESTIA_PUB_KEY || await fetchPubKeyFromR2(R2_ENDPOINT, R2_BUCKET);
            return new Response(pubKey, {
                status: 200,
                headers: {
                    'Content-Type': 'text/plain; charset=utf-8',
                    'Cache-Control': 'public, max-age=86400'
                }
            });
        }
        
        let targetUrl = '';
        const filename = pathname.substring(pathname.lastIndexOf('/') + 1);
        
        if (pathname.endsWith('.pkg') || pathname.endsWith('.txz') || 
            pathname.includes('packagesite') || pathname.includes('digests') || pathname.endsWith('.sh')) {
            if (R2_ENDPOINT) {
                targetUrl = `${R2_ENDPOINT}/${R2_BUCKET}${pathname}`;
            } else {
                targetUrl = `${GITHUB_BASE}/${filename}`;
            }
        }
        
        if (!targetUrl && MIRROR_BASE) {
            targetUrl = `${MIRROR_BASE}${pathname}`;
        }
        
        if (!targetUrl) {
            return new Response('Asset Ledger Entry Not Found', { status: 404 });
        }
        
        try {
            const response = await fetch(targetUrl, {
                headers: {
                    'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36',
                    'Referer': 'https://hestiamb.org'
                }
            });
            
            if (!response.ok) {
                return new Response(`Upstream asset synchronization failed for: ${pathname}`, { status: 404 });
            }
            const headers = new Headers(response.headers);
            headers.set('Access-Control-Allow-Origin', '*');
            headers.set('Access-Control-Allow-Methods', 'GET, HEAD');
            
            if (pathname.endsWith('.pkg') || pathname.endsWith('.txz')) {
                headers.set('Content-Type', 'application/octet-stream');
                headers.set('Cache-Control', 'public, max-age=604800, immutable');
            } else {
                headers.set('Content-Type', pathname.endsWith('.pub') || pathname.endsWith('.sh') ? 'text/plain; charset=utf-8' : 'application/octet-stream');
                headers.set('Cache-Control', 'public, max-age=3600');
            }
            
            return new Response(response.body, {
                status: response.status,
                headers: headers
            });
            
        } catch (error) {
            return new Response(`Gateway Bridge Error: ${error.message}`, { status: 502 });
        }
    }
};

function getClientSetupScript(baseUrl) {
    return `#!/bin/sh
# HestiaCP FreeBSD pkg repository setup script
# Automatically generated and synchronized by Cloudflare Workers Edge Node

REPO_URL="${baseUrl}"
PUB_KEY_URL="${baseUrl}/hestiacp.pub"

echo "=== Configuring HestiaCP FreeBSD pkg Private Repository ==="

if [ "$(id -u)" != "0" ]; then
    echo "Error: This script must be run as root privileges."
    exit 1
fi

mkdir -p /usr/local/etc/pkg/keys
mkdir -p /usr/local/etc/pkg/repos

echo "Downloading public key from cloud edge node..."
fetch -o /usr/local/etc/pkg/keys/hestiacp.pub \${PUB_KEY_URL}
if [ $? -ne 0 ]; then
    echo "Failed to fetch secure public key asset."
    exit 1
fi

cat > /usr/local/etc/pkg/repos/hestiacp.conf << EOF
hestiacp: {
  url: "\${REPO_URL}",
  signature_type: "pubkey",
  pubkey: "/usr/local/etc/pkg/keys/hestiacp.pub",
  enabled: yes,
  mirror_type: "http",
  priority: 100
}
EOF

echo "Updating local package repository metadata ledger..."
pkg update -f

if [ $? -eq 0 ]; then
    echo "=== ✓ Repository configured successfully! ==="
    echo "You can now install core panels via: pkg install hestia"
else
    echo "=== ✗ Repository metadata tracking synchronization failed ==="
    exit 1
fi
`;
}

async function fetchPubKeyFromR2(endpoint, bucket) {
    try {
        const targetUrl = `${endpoint}/${bucket}/hestiacp.pub`;
        const response = await fetch(targetUrl, {
            headers: {
                'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36'
            }
        });
        
        if (response.ok) {
            return await response.text();
        }
    } catch (e) {
        // 静默失败，继续尝试 fallback
    }

    try {
        const FALLBACK_GITHUB_URL = "https://githubusercontent.com";
        const fallbackResponse = await fetch(FALLBACK_GITHUB_URL);
        if (fallbackResponse.ok) {
            return await fallbackResponse.text();
        }
    } catch (fallbackError) {
        // 两个都失败，返回错误信息
    }
    
    return `# Error: Failed to automatically print HestiaCP public key from both R2 storage nodes and GitHub fallbacks.\n# Please verify your Cloudflare network propagation status or contact the repo maintainer.`;
}