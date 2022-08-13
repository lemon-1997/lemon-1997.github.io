cp ./static/lemon.ico ./themes/hugo-theme-next/static/imgs/icons/
cp ./static/lemon.jpg ./themes/hugo-theme-next/static/imgs/
hugo --minify
sed -i 's/baidu-site-verification/"baidu-site-verification"/' ./public/index.html
sed -i 's/msvalidate.01/"msvalidate.01"/' ./public/index.html
sed -i 's/google-site-verification/"google-site-verification"/' ./public/index.html