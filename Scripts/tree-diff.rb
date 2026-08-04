#!/usr/bin/env ruby
# frozen_string_literal: true

# Diffs two `<screen>.tree` dumps written by CaptureGeometryDump (see
# Sources/IceCubesCheck/CaptureGeometryDump.swift, compiled into both the
# interpreter's capture path and the native twin).
#
# `diff` is the wrong tool for these: the two hierarchies legitimately nest
# their hosting views differently, so a single extra wrapper on one side shifts
# every later line and reports a hundred differences where there is one. What
# the R2 board actually needs answered is narrower — "which BOX is not where
# the compiled one is" — so this aligns nodes by the geometry they occupy
# rather than by their position in the file, and reports:
#
#   * boxes present on both sides whose frame differs (sorted by how much),
#   * boxes present on only one side.
#
# A sub-pixel row is the interesting one: a frame off by 0.017 is invisible to
# a pixel diff except as an antialiased edge off by 1/255, which is exactly the
# media screen's remaining residue.
#
# usage: tree-diff.rb twin.tree interp.tree [--epsilon 0.0]

require 'optparse'

epsilon = 0.0
OptionParser.new do |o|
  o.banner = 'usage: tree-diff.rb twin.tree interp.tree [--epsilon N]'
  o.on('--epsilon N', Float, 'ignore frame differences at or below N points') do |v|
    epsilon = v
  end
end.parse!

twin_path, interp_path = ARGV[0], ARGV[1]
abort 'usage: tree-diff.rb twin.tree interp.tree [--epsilon N]' unless twin_path && interp_path
[twin_path, interp_path].each do |p|
  abort "tree-diff: no such dump: #{p}" unless File.file?(p)
end

Node = Struct.new(:name, :x, :y, :w, :h, :flags, :line, :depth) do
  # Identity is the view's class plus its SIZE rounded to whole points. Two
  # sides that lay out the same box agree on both even when a frame differs in
  # the third decimal, which is the case this tool exists for; keying on the
  # exact frame instead would make every divergence look like two unmatched
  # nodes and report nothing.
  def key
    [name, w.round, h.round]
  end

  def frame
    [x, y, w, h]
  end

  def to_s
    format('%s x=%.6f y=%.6f w=%.6f h=%.6f%s',
           name, x, y, w, h, flags.empty? ? '' : " #{flags.join(' ')}")
  end
end

def parse(path)
  # `filter_map` is Ruby 2.7+; the system ruby this runs under is 2.6.
  File.readlines(path, chomp: true).each_with_index.map do |line, index|
    next if line.strip.empty?
    depth = (line[/\A */].length) / 2
    fields = line.strip.split(' ')
    name = fields.shift
    values = {}
    flags = []
    fields.each do |field|
      k, v = field.split('=', 2)
      if v.nil?
        flags << k
      elsif %w[x y w h].include?(k)
        values[k] = v.to_f
      else
        flags << field
      end
    end
    next unless %w[x y w h].all? { |k| values.key?(k) }
    Node.new(name, values['x'], values['y'], values['w'], values['h'],
             flags, index + 1, depth)
  end.compact
end

twin = parse(twin_path)
interp = parse(interp_path)

puts "twin   #{twin.size} nodes  #{twin_path}"
puts "interp #{interp.size} nodes  #{interp_path}"

# Match greedily within an identity bucket, nearest-position first, so repeated
# sibling boxes (rows, media tiles) pair with their counterpart rather than
# with whichever one happens to be listed first.
twin_by_key = twin.group_by(&:key)
interp_by_key = interp.group_by(&:key)

matched = []
unmatched_interp = []
interp_by_key.each do |key, candidates|
  pool = (twin_by_key[key] || []).dup
  candidates.each do |node|
    if pool.empty?
      unmatched_interp << node
      next
    end
    best = pool.min_by { |t| (t.x - node.x).abs + (t.y - node.y).abs }
    pool.delete_at(pool.index(best))
    matched << [best, node]
  end
end
unmatched_twin = twin_by_key.flat_map do |key, nodes|
  taken = matched.count { |t, _| t.key == key }
  nodes.drop(taken)
end

diverged = matched.map do |t, i|
  delta = t.frame.zip(i.frame).map { |a, b| (a - b).abs }.max
  next if delta <= epsilon && t.flags.sort == i.flags.sort
  [delta, t, i]
end.compact.sort_by { |delta, _, _| -delta }

if diverged.empty?
  puts "\nGEOMETRY IDENTICAL — every matched box agrees within #{epsilon}"
else
  puts "\nDIVERGED #{diverged.size} of #{matched.size} matched boxes" \
       " (max delta first)"
  diverged.each do |delta, t, i|
    puts format("\n  delta %.6f  %s", delta, t.name)
    puts format('    twin   x=%.6f y=%.6f w=%.6f h=%.6f%s',
                t.x, t.y, t.w, t.h, t.flags.empty? ? '' : " #{t.flags.join(' ')}")
    puts format('    interp x=%.6f y=%.6f w=%.6f h=%.6f%s',
                i.x, i.y, i.w, i.h, i.flags.empty? ? '' : " #{i.flags.join(' ')}")
    changed = t.flags.sort != i.flags.sort
    puts '    FLAGS DIFFER' if changed
  end
end

unless unmatched_twin.empty?
  puts "\nONLY IN TWIN (#{unmatched_twin.size})"
  unmatched_twin.first(40).each { |n| puts "  #{n}" }
end
unless unmatched_interp.empty?
  puts "\nONLY IN INTERP (#{unmatched_interp.size})"
  unmatched_interp.first(40).each { |n| puts "  #{n}" }
end

exit(diverged.empty? && unmatched_twin.empty? && unmatched_interp.empty? ? 0 : 1)
