#!/bin/bash
# Force-create Vite/React frontend non-interactively.

echo "🧹 Removing old frontend directory..."
rm -rf frontend

echo "📦 Creating Vite/React project (auto-answering prompts)..."
yes | npx create-vite@latest frontend -- --template react --yes

echo "📦 Installing dependencies..."
cd frontend
npm install

echo "🔨 Building React app..."
npm run build
cd ..

echo "✅ Frontend built successfully at frontend/dist/"
ls -la frontend/dist/

echo "🌐 Deploying to gh-pages branch..."
git checkout --orphan gh-pages 2>/dev/null || git checkout gh-pages
git rm -rf . 2>/dev/null || true
cp -r frontend/dist/* .
touch .nojekyll
git add .
git commit -m "Deploy React app" || echo "No changes to commit"
git push origin gh-pages --force

echo "⚙️ Configuring GitHub Pages..."
USERNAME=$(gh api user -q .login)
REPO="resilient-payment-gateway"
gh api repos/$USERNAME/$REPO/pages -X POST -f source='{"branch":"gh-pages","path":"/"}' 2>/dev/null || echo "Pages already configured"

echo "✅ Done!"
echo "Repo: https://github.com/$USERNAME/$REPO"
echo "Pages: https://$USERNAME.github.io/$REPO"
