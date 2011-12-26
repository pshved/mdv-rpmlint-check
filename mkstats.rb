#!/usr/bin/ruby
# Collect rpmlint warnings and errors for many packages

require 'fileutils'
require 'thread'

# Argument list is too long
puts "Input PRM file names to command line, please..."
file_list = []
STDIN.each_line {|fname| file_list << fname.chomp }
RESULTS_DIR = "lints"
BAD_RESULTS_DIR = "bad_reports"

# Get reports
FileUtils.mkdir_p RESULTS_DIR
FileUtils.mkdir_p BAD_RESULTS_DIR

progress = 0.0
nrp = 0.0
step = 1.0/30
statlock = Mutex.new

fq = file_list.dup
file_list.each {|f| fq.push f}

workers = []

# set the env var so that bad signature stuff doesn't make warnings the errors!
ENV['RPMBUILD_MAINTAINER_MODE'] = '1'

def lint_from_rpm(rpm_fname, d = RESULTS_DIR)
	File.join(d,"#{File.basename(rpm_fname)}.txt")
end
def rpm_from_lint(lint_fname)
	/(.*)\.txt$/.match(File.basename(lint_fname))[1]
end

3.times do
	workers << Thread.new do
		while rpm_fname = statlock.synchronize { fq.empty? ? nil : fq.shift }

			lint_fname = lint_from_rpm(rpm_fname)

			statlock.synchronize { progress += 1.0 }

			# emulate "make" behavior
			next if File.exists?(lint_fname) && File.mtime(lint_fname) > File.mtime(rpm_fname)

			puts "Running rpmlint for #{File.basename rpm_fname}..."
			unless Kernel.system("rpmlint '#{rpm_fname}' >#{lint_fname} 2>&1")
				# Record rpmlint failure
				# Since rpmlint now fails on each package, then make it fail silently...
				#puts "rpmlint failure detected!"
				#File.open(lint_fname,"a") {|f| f.puts "foobar: W: rpmlint-has-failed"}
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
results_fnames = file_list.map {|rpm_fname| lint_from_rpm(rpm_fname)} 

# Format : package => array of warnings it exposes
pkg_info = {}
pkg_info_ext = {}

results_fnames.each do |result_f|
	pkg_name = rpm_from_lint result_f

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
File.open("warns_per_pkg_","w") do |f|
	warns_per_package.each_pair do |pkg,warns|
		f.puts "#{warns} #{pkg}"
	end
end
Kernel.system('sort -n -r <warns_per_pkg_ >warns_per_pkg')

# 2. What packages will fail
pkg_status = pkg_info_ext.inject({}) do |acc,kv|
	failmsg = "OK"
	kv[1].each do |msg|
		if md = /badness ([0-9]+) exceeds threshold/.match(msg)
			failmsg = "BAD #{md[1]}" 
			# if so, copy its report to the separate folder
			FileUtils.cp(lint_from_rpm(kv[0]),lint_from_rpm(kv[0],BAD_RESULTS_DIR))
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

Kernel.system('grep BAD pkg_status >bad_packages_')
Kernel.system('sort -n -r -k 2 <bad_packages_ >bad_packages')


