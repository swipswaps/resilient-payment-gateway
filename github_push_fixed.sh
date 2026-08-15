#!/bin/bash
# Automated GitHub push with Pages deployment – no placeholders.

set -e

echo "🔐 Checking GitHub authentication..."
if ! gh auth status &>/dev/null; then
    echo "Please run: gh auth login"
    exit 1
fi

USERNAME=$(gh api user -q .login)
REPO="resilient-payment-gateway"
echo "✅ Using GitHub username: $USERNAME"

echo "📁 Creating repository (if not exists)..."
gh repo view $REPO &>/dev/null || gh repo create $REPO --public --description "Resilient payment gateway" --gitignore Python

echo "📤 Pushing code..."
git init
git add .
git commit -m "Initial commit: full payment gateway" || echo "Already committed"
git remote add origin https://github.com/$USERNAME/$REPO.git 2>/dev/null || git remote set-url origin https://github.com/$USERNAME/$REPO.git
git branch -M main
git push -u origin main --force

echo "📦 Building frontend (Vite/React)..."
mkdir -p frontend
cd frontend
npm create vite@latest . -- --template react --yes
npm install
npm run build
cd ..

echo "🌐 Deploying to gh-pages branch..."
git checkout --orphan gh-pages 2>/dev/null || git checkout gh-pages
git rm -rf . 2>/dev/null || true
cp -r frontend/dist/* .
touch .nojekyll
git add .
git commit -m "Deploy React app" || echo "No changes to commit"
git push origin gh-pages --force

echo "⚙️ Configuring GitHub Pages..."
gh api repos/$USERNAME/$REPO/pages -X POST -f source='{"branch":"gh-pages","path":"/"}' 2>/dev/null || echo "Pages already configured"

echo "✅ Done!"
echo "Repo: https://github.com/$USERNAME/$REPO"
echo "Pages: https://$USERNAME.github.io/$REPO"
