pack:
	tar --exclude="*.swp" -czf early.tgz root tmp usr
	tar --exclude="*.swp" -czf late.tgz mnt
