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
		attr_reader :row, :col, :rowcol
		attr_accessor :ants, :food
		attr_accessor :nest, :tracer
		def initialize(world, rowcol)
			@row = rowcol.first
			@col = rowcol.last
			@rowcol = rowcol.dup
			@nest = nil # index of the nest in the cell, nil if none
			@ants = [] # indices of the ants in the cells, if any
			# number of food packages of each kind, plus dead ants (at index 0)
			@food = Array.new(world.options[:nfp] + 1, 0)
			@tracer = 0
		end
	end

	class Ant
		# row, col delta for each of the 8 directions
		# clockwise from (-1, -1)
		DIR = [
			[-1, -1],
			[-1, 0],
			[-1, 1],
			[0, 1],
			[1, 1],
			[1, 0],
			[1, -1],
			[0, -1]]

		attr_reader :nest, :id, :cell, :food, :health
		attr_reader :last_motion_weight, :last_motion_dir
		def initialize(_nest, _id)
			@world = _nest.world
			@nest = _nest
			@id = _id
			@cell = nest.cell
			# ant health
			@health = @world.options[:af]
			# carried food
			@food = 0
			# weight of each direction. initially, all equal
			@dir_weight = Array.new(8, 1)
			# weight of the last motion taken, used to
			# resolve conflicts in picking up food
			@last_motion_weight = 0
			# direction of the last motion taken, used to
			# resolve conflicts in picking up food
			@last_motion_dir = [0, 0]
		end

		# decide what to do on this turn
		def ponder_action
			other = (@cell.ants - [self]).first
			cell_food = @cell.food.inject(0, :+)
			if @food > 0
				# if carrying food
				# (1) if there is an ant in the same cell with low health
				#     and no food, pass food to them unless there is food
				#     in the cell
				# (2) else if we have less than half max health, eat
				# (3) else if we are on nest, drop food
				# (4) else move
				if other and other.food == 0 and cell_food == 0 and other.health < (@health+1)/2
					return [:pass_food, other]
				elsif @health < @world.options[:af]/2
					return [:eat_food]
				elsif @cell.nest == @nest
					return [:drop_food, @food]
				else
					return ponder_motion
				end
			else
				# if not carrying food
				# (1) if there is food, pick food
				# (2) else if there is an ant with food and high health, get food from them
				# (3) else move
				if cell_food > 0
					return [:pick_food, @cell]
				elsif other and other.food > 0 and @health < (other.health+1)/2
					return [:get_food, other]
				else
					return ponder_motion
				end
			end
		end

		# where do we wan to go today?
		def ponder_motion
			# build weight of each direction, multiplying the
			# dir_weight by the amount of tracer in the
			# cell
			dircand = -1
			weights = []
			total = 0
			@dir_weight.each_with_index do |d, i|
				t = @world.cell_off(@cell.rowcol, DIR[i]).tracer
				w = d*(t+d)
				weights << w
				total += w
			end
			where = rand(total)
			weights.each_with_index.inject(0) do |sum, (w, idx)|
				sum += w
				if where < sum
					dircand = idx
					break
				end
				sum
			end
			puts "ant %s: %u/%u in %s => %u" % [self, where, total, weights, dircand]
			return [:moveto, @dir_weight[dircand], DIR[dircand], @world.cell_off(@cell.rowcol, DIR[dircand])]
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

		# cell plus offset
		def cell_off(rowcol, offset)
				@world[ self.rc(rowcol.first + offset.first, rowcol.last + offset.last) ]
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

		# gather ant choices
		def gather_actions
			candidate = {}
			accepted = {}
			discarded = {}
			# cell-indexed potential conflicts
			pick_conflicts = Hash.new { |h, k| Hash.new }
			motion_conflicts = Hash.new { |h, k| Hash.new }

			@ants.each do |a|
				candidate[a] = a.ponder_action
			end

			while aa = candidate.shift do
				puts "%s => %s" % aa
				ant, action = aa
				case action.first
				when :eat_food, :drop_food
					accepted[ant] = action
				when :pass_food
					other_action = candidate[action.last]
					if other_action.first != :get_food or other_action.last != ant
						throw "inconsistent actions! %s / %s vs %s / %s" % [ant, action, action.last, other_action]
					else
						accepted[ant] = action
					end
				when :get_food
					other_action = candidate[action.last]
					if other_action.first != :pass_food or other_action.last != ant
						throw "inconsistent actions! %s / %s vs %s / %s" % [ant, action, action.last, other_action]
					else
						accepted[ant] = action
					end
				when :moveto
					motion_conflicts[action.last][ant] = action
				when :pick_food
					pick_conflicts[action.last][ant] = action
				end
			end

			throw "wtf candidate" unless candidate.empty?

			# solve pick conflicts
			# TODO
			# solve motion conflicts
			# TODO
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
		world.gather_actions
		world.generate_ants
		# blah blah
		world.display
	end

end

# vi: sw=2 ts=2 noet
