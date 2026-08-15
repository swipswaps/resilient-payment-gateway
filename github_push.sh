#!/bin/bash
# Push to GitHub and deploy Pages.

# Replace with your GitHub username
USERNAME="YOUR_GITHUB_USERNAME"
REPO="resilient-payment-gateway"

# Authenticate (if not already)
gh auth login

# Create repository
gh repo create $REPO --public --description "Resilient payment gateway" --gitignore Python

# Push code
git init
git add .
git commit -m "Initial commit: full payment gateway"
git remote add origin https://github.com/$USERNAME/$REPO.git
git branch -M main
git push -u origin main

# Build frontend (Vite/React)
mkdir -p frontend
cd frontend
npm create vite@latest . -- --template react
npm install
npm run build
cd ..

# Deploy to gh-pages
git checkout --orphan gh-pages
git rm -rf .
cp -r frontend/dist/* .
touch .nojekyll
git add .
git commit -m "Deploy React app"
git push origin gh-pages

# Configure Pages via API
gh api repos/$USERNAME/$REPO/pages -X POST -f source='{"branch":"gh-pages","path":"/"}'

echo "✅ GitHub repo created: https://github.com/$USERNAME/$REPO"
echo "✅ Pages will be live at: https://$USERNAME.github.io/$REPO"
