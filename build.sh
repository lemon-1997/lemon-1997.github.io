# add img
cp ./static/lemon.ico ./themes/hugo-theme-next/static/imgs/icons/
cp ./static/lemon.jpg ./themes/hugo-theme-next/static/imgs/
# gen static
hugo --minify
# fix tag quote
sed -i 's/baidu-site-verification/"baidu-site-verification"/' ./public/index.html
sed -i 's/msvalidate.01/"msvalidate.01"/' ./public/index.html
sed -i 's/google-site-verification/"google-site-verification"/' ./public/index.html
# seo url
cp ./public/sitemap.xml ./public/sitemap-vercel.xml
sed -i 's/lemon-1997.github.io/lemon-1997-github.io.vercel.app/g' ./public/sitemap-vercel.xml