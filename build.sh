# add img
cp ./static/lemon.ico ./themes/hugo-theme-next/static/imgs/icons/
cp ./static/lemon.jpg ./themes/hugo-theme-next/static/imgs/
# code font
sed -i '$ s/$/\n\npre, code {\n\  font-size: 13.5px;\n}/' ./themes/hugo-theme-next/assets/css/_common/scaffolding/highlight/index.scss
# local search
sed -i 's/fetch(this.path)/fetch(new URL(this.path, location.origin).href)/' ./themes/hugo-theme-next/assets/js/third-party/search/local.js
sed -i 's/element.querySelector('\''url'\'').textContent/element.querySelector('\''url'\'').textContent.replace('\''https\:\/\/lemon-1997.github.io\/'\'', '\'''\'')/' ./themes/hugo-theme-next/assets/js/third-party/search/local.js
# gen static
hugo --minify
# fix tag quote
sed -i 's/baidu-site-verification/"baidu-site-verification"/' ./public/index.html
sed -i 's/msvalidate.01/"msvalidate.01"/' ./public/index.html
sed -i 's/google-site-verification/"google-site-verification"/' ./public/index.html
# seo url
cp ./public/sitemap.xml ./public/sitemap-cf.xml
sed -i 's/lemon-1997.github.io/lemon-1997.pages.dev/g' ./public/sitemap-cf.xml