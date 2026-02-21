pack:
	tar --exclude="*.swp" -czf early.tgz root var usr
	tar --exclude="*.swp" -czf late.tgz mnt
