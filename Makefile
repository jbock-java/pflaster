pack:
	tar --exclude="*.swp" --exclude="*.cfg" --exclude="*.tgz" --exclude=".git" --exclude=".gitignore" --exclude="Makefile" -czf root.tgz .
