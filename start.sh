#!/bin/bash

echo "=== Jekyll 로컬 서버 시작 ==="
echo ""

# Homebrew Ruby 사용
export PATH="/opt/homebrew/opt/ruby/bin:$PATH"

echo "Jekyll 서버 시작 중..."
echo "브라우저에서 http://localhost:4000 으로 접속하세요"
echo ""
echo "종료하려면 Ctrl+C를 누르세요"
echo ""

lsof -ti:4000 | xargs kill -9 && bundle exec jekyll serve --livereload

