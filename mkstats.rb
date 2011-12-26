#!/usr/bin/ruby
# Collect rpmlint warnings and errors for many packages

require 'fileutils'
require 'thread'

# Argument list is too long
puts "Input PRM file names to command line, please..."
file_list = []
STDIN.each_line {|fname| file_list << fname.chomp }
results_dir = "lints"

# Get reports
FileUtils.mkdir_p results_dir

progress = 0.0
nrp = 0.0
step = 1.0/30
statlock = Mutex.new

fq = file_list.dup
file_list.each {|f| fq.push f}

workers = []

3.times do
	workers << Thread.new do
		while rpm_fname = statlock.synchronize { fq.empty? ? nil : fq.shift }

			lint_fname = File.join(results_dir,File.basename(rpm_fname))

			statlock.synchronize { progress += 1.0 }

			# emulate "make" behavior
			next if File.exists?(lint_fname) && File.mtime(lint_fname) > File.mtime(rpm_fname)

			puts "Running rpmlint for #{File.basename rpm_fname}..."
			unless Kernel.system("rpmlint '#{rpm_fname}' >#{lint_fname} 2>&1")
				# Record rpmlint failure
				# Since rpmlint now fails on each package, then make it fail silently...
				#puts "rpmlint failure detected!"
				File.open(lint_fname,"a") {|f| f.puts "foobar: W: rpmlint-has-failed"}
			end

			statlock.synchronize do
				if (progress / file_list.length > nrp)
					nrp += step	while progress / file_list.length >= nrp
					printf "Completed: %.1f%%\n", ((nrp-step)*100)
				end
			end
		end
	end
end

workers.each {|w| w.join}

# Collect stats
results_fnames = file_list.map {|rpm_fname| File.join(results_dir,File.basename(rpm_fname))} 

# Format : package => array of warnings it exposes
pkg_info = {}
pkg_info_ext = {}

results_fnames.each do |result_f|
	pkg_name = File.basename result_f

	pin = pkg_info[pkg_name] = []
	pex = pkg_info_ext[pkg_name] = []

	lines = IO.readlines result_f
	lines.each do |ln|
		if md = /^\S+: (.): (\S+)(.*)/.match(ln)
			type, kind, ext = md[1],md[2],md[3]
			pin << kind
			pex << kind+ext
		end
	end
end

#puts pkg_info.inspect

# Prepare reports

# 1. Warnings per package
warns_per_package = pkg_info.inject({}) {|acc,kv| acc[kv[0]] = kv[1].length; acc}
File.open("warns_per_pkg","w") do |f|
	warns_per_package.each_pair do |pkg,warns|
		f.puts "#{warns} #{pkg}"
	end
end

# 2. What packages will fail
pkg_status = pkg_info_ext.inject({}) do |acc,kv|
	failmsg = "OK"
	kv[1].each do |msg|
		if md = /badness ([0-9]+) exceeds threshold/.match(msg)
			failmsg = "BAD #{md[1]}" 
		end
	end
	acc[kv[0]] = failmsg
	acc
end
File.open("pkg_status","w") do |f|
	pkg_status.each_pair do |pkg,warns|
		f.puts "#{warns} #{pkg}"
	end
end


