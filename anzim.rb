#!/usr/bin/ruby

=begin
ANZIM world food generation routine
=end

module ANZIM

	DEFAULTS = {
		ws: 1024, # world side
		af: 256, # ant food/health
		at: 256, # ant tracer
		sf: 1024, # small food package
		bf: 8192, # big food package
	}

	class Cell
		attr_reader :row, :col
		attr_reader :ants, :food
		attr_accessor :nest
		def initialize(world, rowcol)
			@row = rowcol.first
			@col = rowcol.last
			@nest = nil # index of the nest in the cell, nil if none
			@ants = [] # indices of the ants in the cells, if any
			# number of food packages of each kind, plus dead ants (at index 0)
			@food = Array.new(world.options[:nfp] + 1, 0)
		end
	end

	class Ant
		attr_reader :nest, :id, :cell
		def initialize(_nest, _id)
			@nest = _nest
			@id = _id
			@cell = nest.cell
			# ant health
			@health = @nest.world.options[:af]
			# carried food
			@food = 0
		end
	end

	class Nest
		attr_reader :world, :cell
		attr :food
		def initialize(_world, _cell)
			@world = _world
			@cell = _cell
			@next_ant = 0
			# start with enough food to generate a line of ants as long
			# as the world
			@food = @world.options[:af]*@world.options[:ws]
		end

		# generate ant. this is called by the world if there aren't
		# already two ants on the cell
		def generate_ant
			ant = nil
			if @food >= @world.options[:af]
				ant = Ant.new(self, @next_ant)
				@food -= @world.options[:af]
				@next_ant +=1
			end
			return ant
		end

	end

	class World
		attr_reader :options

		def initialize(_opts={})
			@options = DEFAULTS.dup.merge _opts

			# number of possible food packages
			@options[:nfp] = 1 + Math.log2(@options[:bf]/@options[:sf])

			# the world is a hash of cells indexed by (row, col)
			@world = Hash.new { |h, rowcol|
				h[rowcol] = Cell.new(self, rowcol)
			}

			# nests
			@nests = []
			@ants = []

			# food generation is probabilistic, and based on the amount of
			# food on each row/col. However, to simplify the calculation,
			# we actually keep track of the _chance_ per row/col
			@rowchance = [] # chance to produce food, per row
			@colchance = [] # chance to produce food, per col
			ws = @options[:ws]
			ws.times do
				@rowchance << 1
				@colchance << 1
			end
			@rowchancetotal = @colchancetotal = ws
		end

		# actual [row, col] 
		def rc(row, col)
			ws = @options[:ws]
			[row % ws, col % ws] # classic toroidal world
		end

		# does cell at (row, col) exist?
		def has_cell?(row, col)
			@world.has_key? self.rc(row, col)
		end

		# cell at (row, col)
		def cell(row, col)
			@world[ self.rc(row, col) ]
		end

		# generate a new nest
		def generate_nest
			ws = @options[:ws]
			r = rand(ws)
			c = rand(ws)
			# TODO in the future, when nests may be generated at runtime,
			# we should check that there are no food or ants in the place
			cc = self.cell(r, c)
			nn = Nest.new(self, cc)
			cc.nest = nn
			@nests << nn
		end

		# generate ants
		# TODO conflict resolution
		def generate_ants
			@nests.each do |n|
				if n.cell.ants.length < 2
					ant = n.generate_ant # generate an ant
					next if ant.nil? # could not generate (not enough food)
					@ants << ant
					n.cell.ants << ant
				end
			end
		end

		# add food at index idx of cell c
		def add_food(c, idx)
			ws = @options[:ws]
			c.food[idx] += 1

			@rowchance[(c.row - 1)%ws] += 1
			@rowchance[c.row] += 1
			@rowchance[(c.row + 1)%ws] += 1
			@rowchancetotal += 3

			@colchance[(c.col - 1)%ws] += 1
			@colchance[c.col] += 1
			@colchance[(c.col + 1)%ws] += 1
			@colchancetotal += 3
		end

		def generate_food
			rx = rand(3) - 1
			cx = rand(3) - 1
			if rx != 0  or cx != 0
				puts "rx %u cx %u => bailing" % [rx, cx]
				return
			end

			ws = @options[:ws]

			# candidate row, column
			rowcand = -1
			colcand = -1

			# roll!
			rowroll = rand(@rowchancetotal)
			colroll = rand(@colchancetotal)

			puts "row: %u\tin %s" % [rowroll, @rowchance]
			puts "col: %u\tin %s" % [colroll, @colchance]

			@rowchance.each_with_index.inject(0) do |sum, (c, idx)|
				sum += c
				if rowroll < sum
					rowcand = idx
					break
				end
				sum
			end

			@colchance.each_with_index.inject(0) do |sum, (c, idx)|
				sum += c
				if colroll < sum
					colcand = idx
					break
				end
				sum
			end

			puts "( %u/%u, %u/%u )" % [rowcand, ws, colcand, ws]

			cc = self.cell(rowcand, colcand)

			# only generate food if not nest and there are no ants
			unless cc.nest.nil? and cc.ants.empty?
				puts "nest: %s, ants: %s => bailing" % [cc.nest, cc.ants]
				return
			end

			# we generate a random package among the ones available
			# to do this, we create an array of the available indices
			# and pick a random one
			indices = []
			cc.food.each_with_index do |v, i|
				next if i == 0 # skip dead ants
				(2 - v).times do
					indices << i
				end
			end
			if indices.empty?
				puts "%s: cell full => bailing" % [cc.food]
				return
			end

			idx = indices.shuffle.first
			puts "food package %u in %s" % [idx, indices]
			self.add_food(cc, idx)
		end

		# show the world
		def display
			# world size
			ws = @options[:ws]
			# cell width: take into account food packages (top row)
			# and live/dead ants (bottom row)
			# add 2 for padding
			cw = [@options[:nfp], 4].max + 2
			ch = 4 # padding, food packages, ants, padding

			# horizontal/vertical step, taking border into account
			hstep = cw + 1
			vstep = ch + 1

			# display rows
			dr = Array.new(vstep*ws) { String.new }

			# horizontal line
			hline = "+" + ("-"*cw)
			# padding
			padline = "|" + (" "*cw)
			# nest padding
			nestline = "|·" + (" "*(cw-2)) + "·"


			ws.times do |row|
				ws.times do |col|

					cc = nil
					nest = nil
					if self.has_cell?(row, col)
						cc = self.cell(row, col)
						nest = cc.nest
					end

					if cc.nil?
						foodline = padline
					else
						foodline = "| "
						cc.food.drop(1).each do |np|
							foodline << case np
							when 0
								" "
							when 1
								"▃"
							when 2
								"█"
							else
								throw "too much food @ (%u, %u)" % [row, col]
							end
						end
						foodline << " " while foodline.length < hstep
					end

					if cc.nil?
						antline = padline
					else
						antline = "| "
						antline << ("*" * cc.ants.length)
						antline << (" " * (2 - cc.ants.length))
						cc.food.first do |a|
							antline << case a
							when 0
								"  "
							when 1
								"x "
							when 2
								"xx"
							else
								throw "too many dead ants @ (%u, %u)" % [row, col]
							end
						end
						antline << " " while antline.length < hstep
					end

					lastcol = (col == ws - 1)

					base = vstep*row
					dr[base] << hline.dup
					dr[base] << "+" if lastcol

					base += 1
					dr[base] << ( nest ? nestline : padline ).dup
					dr[base] << "|" if lastcol

					base += 1
					dr[base] << foodline.dup
					dr[base] << "|" if lastcol

					base += 1
					dr[base] << antline.dup
					dr[base] << "|" if lastcol

					base += 1
					dr[base] << ( nest ? nestline : padline ).dup
					dr[base] << "|" if lastcol
				end
			end

			# repeat top line at bottom
			dr << dr.first
			puts dr.join("\n")
		end

	end

end

if __FILE__ == $0

	world = ANZIM::World.new(ws: 8)
	world.generate_nest
	world.display

	while true
		world.generate_food
		world.generate_ants
		# blah blah
		world.display
	end

end

# vi: sw=2 ts=2 noet
