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

		def evaporate
			@tracer /= 2
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
		# weights for the directions, from the one we came from
		WEIGHTS = [
			1, 2, 4, 8, 16, 8, 4, 2
		]


		attr_reader :nest, :id, :cell, :food, :health
		attr_reader :last_motion_weight, :last_motion_dir
		attr_reader :prev_cell
		def initialize(_nest, _id)
			@world = _nest.world
			@nest = _nest
			@id = _id
			@cell = nest.cell
			@prev_cell = @cell
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

		# decrease health by 1
		def lived
			@health -= 1
		end

		# die
		def die
			throw "I cannot die now!" if @food
			@cell.ants.delete self
			@cell.food[0] += 1
		end

		# returns 1 if the ant has food, 0 otherwise
		# used for conflict resolution
		# use 1 and 0 so that results can be compared with <=>
		def has_food
			return 1 if @food > 0
			return 0
		end

		# returns 1 if the ant was in the cell already, 0 otherwise
		# used for conflict resolution
		# use 1 and 0 so that results can be compared with <=>
		def was_there
			return 1 if @cell == @prev_cell
			return 0
		end

		# returns 1 if a direction is horizontal or vertical,
		# 0 if it's diagonal
		# used for conflict resolution
		# use 1 and 0 so that results can be compared with <=>
		def is_horzvert(dir)
			return 1 if dir.first == 0 or dir.last == 0
			return 0
		end

		# returns 1 if the ant moved into the current cell from
		# a horizontally or vertically adjacent cell, 0 if it
		# moved in diagonally
		# used for conflict resolution
		# use 1 and 0 so that results can be compared with <=>
		def last_motion_horzvert
			return is_horzvert(@last_motion_dir)
		end

		# check if we are hungry
		def hungry?
			@health < @world.options[:af]/2
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
				elsif self.hungry?
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

		# actual ant actions follow

		# pass food to other ant. parameter 'other' isn't really used
		def pass_food(other, _food)
			@food = _food
			self.flip_weights
		end

		# get food from other ant: works exactly the same way as pass_food
		# but we also check if we are hungry, and eat if necessary
		def pass_food(other, _food)
			@food = _food
			self.flip_weights
			self.eat_food if self.hungry?
		end

		# eat food
		def eat_food
			missing = @world.options[:af] - @health
			eats = [missing, @food].min
			@food -= eats
			@health += eats
			if @food == 0
				self.flip_weights # we lost all our food, go back
			else
				self.stay
			end
		end

		# drop food to nest. parameter not really used
		def drop_food(food)
			@cell.nest.food += @food
			@food = 0
			self.flip_weights
		end

		# pick food from cell (and eat if hungry)
		def pick_food(cell, index)
			@cell.food[index] -= 1
			if index == 0
				@food = @world.options[:af]
			else
				index -= 1
				@food = @world.options[:sf]*(2**index)
			end
			self.flip_weights
			self.eat_food if self.hungry?
		end

		# after picking or dropping or passing food, all weights must be reversed
		def flip_weights
			@dir_weight.rotate! 4
			self.stay # we didn't change cell
		end

		# things to do when we didn't change cell
		def stay
			@prev_cell = @cell
		end

		# move to other cell
		def moveto(weight, dir, newcell)
			@cell.tracer += 256
			@cell.ants.delete self
			@prev_cell = @cell
			@cell = newcell
			@cell.ants << self

			@dir_weight.replace WEIGHTS.rotate(4 - DIR.index(dir))
			@last_motion_weight = weight
			@last_motion_dir = dir
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
			return {} if @ants.empty?

			candidate = {}
			accepted = {}
			discarded = {}
			# cell-indexed potential conflicts
			pick_conflicts = Hash.new { |h, k| h[k] = Hash.new }
			motion_conflicts = Hash.new { |h, k| h[k] = Hash.new }

			@ants.each do |a|
				candidate[a] = a.ponder_action
			end

			while (aa = candidate.shift)
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
						action << other.food # should be 0
						accepted[ant] = action
					end
				when :get_food
					other_action = candidate[action.last]
					if other_action.first != :pass_food or other_action.last != ant
						throw "inconsistent actions! %s / %s vs %s / %s" % [ant, action, action.last, other_action]
					else
						action << other.food
						accepted[ant] = action
					end
				when :moveto
					motion_conflicts[action.last][ant] = action
				when :pick_food
					pick_conflicts[action.last][ant] = action
				end
			end

			throw "wtf candidate" unless candidate.empty?

			puts "accepted: %s" % [accepted]
			puts "discarded: %s" % [discarded]
			puts "picks: %s" % [pick_conflicts]
			puts "motions: %s"% [motion_conflicts]

			# solve pick conflicts. this is quite easy, since each cell can be handled independently
			while (pc = pick_conflicts.shift)
				break if pc.empty?
				puts "%s => %s" % pc
				cell, aa = pc
				food_indices = []
				cell.food.each_with_index do |v, i|
					v.times { food_indices << i }
				end
				# sort ants by priority
				ants = aa.keys.sort do |a1, a2|
					# who was there has priority
					cond = (a1.was_there <=> a2.was_there)
					# horz/vert motion has priority
					cond = (a1.last_motion_horzvert <=> a2.last_motion_horzvert) if cond == 0
					# higher weight in last motion has priority
					cond = (a1.last_motion_weight <=> a2.last_motion_weight) if cond == 0
					# younger (higher id) has priority
					cond = (a1.id <=> a2.id) if cond == 0
					throw "wtf %s <=> %s" % [a1, a2] if cond == 0
					cond
				end
				puts "%s <= %s" % [ants, food_indices]
				# assign available food indices to ants following priority
				until food_indices.empty? do
					ant = ants.pop
					fi = food_indices.pop
					action = aa[ant]
					action << fi
					accepted[ant] = action
				end
				# if there are any remaining ants, discard them
				until ants.empty? do
					ant = ants.pop
					action = aa[ant]
					discarded[ant] = action
				end
			end

			# solve motion conflicts
			# this is way more delicate, since there is the possibility
			# that cycles will form
			# we start by eliminating the obviously accepted/discarded ones
			# this must be done iteratively, since it requires knowledge about
			# the ants that move out of the cell
			changed = true
			while changed
				changed = false
				motion_conflicts.each do |cell, aa|
					wanting = aa.size

					puts "%s want to move to %s" % [aa.keys.map { |a| a.id }, cell]

					# count the number of places that are surely available
					# and the number of places that are surely NOT available
					available = 2 - cell.ants.length
					blocked = 0
					# increment the number of available places by the number
					# of ants in the target cell which are moving away
					cell.ants.each do |a|
						# if the ant is known to be moving out, increment availability
						# if it's known to NOT be moving out, increment block
						if accepted[a]
							if accepted[a].first == :moveto
								available += 1
							else
								blocked += 1
							end
							next
						end
						# increment block also if the ant had a :moveto plan that was discarded
						blocked += 1 if discarded[a] and discarded[a].first == :moveto
					end
					# increment block also if cell is a nest with enough food to generate a new ant
					blocked += 1 if cell.nest and cell.nest.food >= @options[:af]
					# finally, increment blocked and decrement available by all accepted ants that want to move here
					accepted.each do |ant, action|
						if action.first == :moveto and action.last == cell
							available -= 1
							blocked += 1
						end
					end

					puts "%s has %s avail, %s blocked, %s wanting" % [cell, available, blocked, wanting]

					# if everything is blocked, discard all
					if blocked >= 2
						discarded.merge! aa
						motion_conflicts.delete cell
						changed = true
						puts "blocked, discarding wanting"
						next
					end

					# if there's room for everybody, go for it
					if wanting <= available
						accepted.merge! aa
						motion_conflicts.delete cell
						changed = true
						puts "available, accepting all"
						next
					end

					# if there are no known available places, skip (can't do nothing to solve conflict yet)
					next if available == 0

					# finally, we get here if there is room for one ant to move in, and we need to find which
					# sort ants by priority
					ant = aa.keys.sort do |a1, a2|
						# horz/vert motion has priority
						cond = (a1.is_horzvert(aa[a1][2]) <=> a2.is_horzvert(aa[a2][2]))
						# with food has higher priortiy
						cond = (a1.has_food <=> a2.has_food) if cond == 0
						# lower health has higher priority (note the a1/a2 swap)
						cond = (a2.health <=> a1.health) if cond == 0
						# higher weight in motion has priority
						cond = (aa[a1][1] <=> aa[a2][1]) if cond == 0
						# younger (higher id) has priority
						cond = (a1.id <=> a2.id) if cond == 0
						throw "wtf %s <=> %s" % [a1, a2] if cond == 0
						cond
					end.last

					accepted[ant] = aa[ant]
					aa.delete ant
					puts "accepting %s" % [ant.id]
					changed = true
				end
			end
			# TODO loop detection/handling
			throw NotImplementedError, "loop detection" if motion_conflicts.size > 0

			puts discarded
			puts accepted

			return accepted
		end

		# evaporate tracer
		def evaporate
			@world.each do |rowcol, cell|
				cell.evaporate
			end
		end

		# decrease health on all ants by 1, check if they died,
		# act accordingly
		def ant_life
			@ants.each do |ant|
				ant.lived
				if ant.health < 0
					ant.die
					@ants.delete ant
				end
			end
		end

		# process valid actions
		def process_actions(accepted)
			@ants.each do |ant|
				if accepted.key? ant
					action = accepted[ant]
					ant.send(*action)
				else
					ant.stay
				end
			end
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

		ANTID = ('0'..'9').to_a + ('a'..'z').to_a + ('A'..'Z').to_a

		# show the world
		def display
			# world size
			ws = @options[:ws]
			# cell width: take into account food packages (top row)
			# and live/dead ants/tracer (bottom row)
			# add 5 for tracer/nest food amount
			# add 2 for padding
			cw = [@options[:nfp], 5].max + 2
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
					elsif nest
						foodline = "| %#{cw-2}u " % nest.food
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
						cc.ants.each do |ant|
							antline << ANTID[ant.id % ANTID.length]
						end
						antline << (" " * (2 - cc.ants.length))
						antline << case cc.food.first
						when 0
							"  "
						when 1
							"x "
						when 2
							"xx"
						else
							throw "too many dead ants @ (%u, %u)" % [row, col]
						end
						antline << case cc.tracer
						when 0
							" "
						else
							tracer = Math.log2(cc.tracer).to_i
							tracer = [[0, tracer].max, 7].min
							[0x2581 + tracer].pack("U")
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
	world.options[:ws].times do
		world.generate_food
		world.generate_food
		world.generate_food
	end
	world.display

	puts "simulation starts now"

	while true
		world.generate_food
		world.evaporate
		world.process_actions world.gather_actions
		world.ant_life
		world.generate_ants
		world.display
		STDOUT.flush
	end

end

# vi: sw=2 ts=2 noet
