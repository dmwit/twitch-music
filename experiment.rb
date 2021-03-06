# The "choose" from combinatorics (hence the extra c on the beginning). Sonic
# Pi already stole the shorter name "choose", dang.
def cchoose(m, n)
	(m-n+1 .. m).inject(1,:*) / (2 .. n).inject(1,:*)
end

StepRange = 4 # maybe jumps of more than a fifth don't sound good, who knows

def melody_transition_weights(from_)
	max = 2*StepRange
	# We will use Fisher's noncentral hypergeometric distribution. For
	# parameters, we choose:
	#
	# * The urn contains `max` red balls and `max` white balls.
	# * We condition on having selected `max` total balls out of the urn.
	# * The odds ratio of red to white balls is selected to make the mode be
	#   `from`. What's more, we set the ratio to make it maximally clear that the
	#   mode is `from`; there is a formula for the mode of the form
	#
	#       mode = floor(f(ratio))
	#
	#   where f is a nice smooth function, and we choose ratio so that
	#   f(ratio) = from + 0.5.
	#
	#   The above discussion is complicated mildly by the fact that we want our
	#   inputs and outputs to be in the range `-StepRange` to `StepRange`, but
	#   the distribution is specified as being in the range `0` to `max`. It's an
	#   easy conversion, though.
	
	# from_ is in [-StepRange, StepRange]; from is in [0, max]
	from = from_ + StepRange
	ratio = ((from+0.5)/(max-from+0.5))**2
	weights = {}
	(-StepRange..StepRange).each do |to_|
		to = to_ + StepRange
		weights[to_] = cchoose(max, to) * cchoose(max, max-to) * ratio**to
	end
	weights
end

# memoize melody_transition_weights
MelodyTransitionWeights = Hash.new { |h,k| h[k] = melody_transition_weights(k) }

# Weighted (hence the extra w on the beginning) random choice. Hand it a
# dictionary mapping possible results to nonnegative weights. It will choose
# one of the results with probability proportional to its weight.
def wchoose(weights)
	sum = weights.inject(0) { |sum_so_far,kv| sum_so_far+kv[1] }
	# TODO: check that this is actually doing what you want (in basic Ruby, you'd want rand()*sum)
	target = rand sum
	current = 0
	weights.each do |kv|
		current += kv[1]
		return kv[0] if target <= current
	end
	raise "The impossible happened in wchoose: we picked a random number bigger than the sum of the weights.\n\ttarget: #{target}\n\tweights: #{weights}"
end

# Like sonic pi's builtin scale function, but handles negative indices.
def major(tonic, ix)
	half_tones = [0,2,4,5,7,9,11]
	Note.new(tonic).midi_note + 12*(ix/7) + half_tones[ix%7]
end

# MinNote and MaxNote must be at least 2*StepRange apart so that we can arrange
# to always be in bounds after one step.
MaxNote = 10 # an octave and a half ought to be enough for anybody
MinNote = -4

def clip(lo,hi,n)
	[lo, [hi, n].min].max
end

# Given a minimum note value, maximum note value, current note value, and a
# "desired" step, take a random step about as big as the "desired" step that
# doesn't go out of the given range.
def melody_step(lo, hi, n, step)
	offset = 0
	if lo+StepRange >= n then
		offset = lo+StepRange - n
	elsif hi-StepRange <= n then
		offset = hi-StepRange - n
	end
	step = clip(-StepRange, StepRange, step-offset)
	n + wchoose(MelodyTransitionWeights[step]) + offset
end

# TODO: account for leading tones, like -1 -> 0, 3 -> 4, 6 -> 7, etc.
def random_melody()
	current_note = 0
	current_peak = 0
	melody = []

	# Trend roughly upward (by using a distribution that very slightly favors
	# stepping up over stepping down). If the note we just arrived at is
	# maximal, choose it as *the* maximum with a probability that gets higher
	# the closer it is to MaxNote.
	while true do
		melody << current_note
		current_note = melody_step(MinNote, MaxNote, current_note, 2)
		if current_note > current_peak then
			current_peak = current_note
			break if rand < (1.0*current_note)/MaxNote
		end
	end

	# Trend roughly tonic-wards, avoiding the peak, until we hit the tonic.
	while current_note != 0 do
		melody << current_note
		top = current_peak
		top -= 1 if current_note != current_peak
		current_note = melody_step(MinNote, top, current_note, 0 <=> current_note)
	end

	melody
end

# random_attacks(a,b) samples b elements uniformly at random without
# replacement from 0 to a-1, returning a set of the sampled elements.
def random_attacks(total_beats, attack_beats)
	result = Set.new
	while result.size < attack_beats do
		result << choose(0..total_beats-1)
	end
	result
end

# random_partition(a,b) selects a random interval partitioning of size b of the
# set of integers 0 to a-1 (TODO: from what distribution, exactly? is it
# uniform?), returning the lengths of each partition in order.
def random_partition(total_beats, attack_beats)
	attacks = random_attacks(total_beats-1, attack_beats-1).to_a.sort.map {|n| n+1}
	([0] + attacks).zip(attacks + [total_beats]).map {|start,stop| stop-start}
end

# Must be less than 1
RhythmDensity = 5.0/16

# A mild variant of the Viterbi algorithm. Given a hidden Markov model and a
# string of observations, sample from the distribution of hidden-state
# sequences generated by the model conditioned on producing the given
# observations.
#
# The arguments are:
# * A hash map `stated` giving the initial state distribution:
#
#       P(s_0 = s) = stated[s]
#
# * A hash map `transitionds` giving the state transition distributions:
#
#       P(s_{i+1} = s | s_i = s') = transitionds[s'][s]
#
# * A hash map `observationds` giving the observation distributions:
#
#       P(o_i = o | s_i = s) = observationds[s][o]
#
# * An array `observations` giving the observations made:
#
#       o_i = observations[i]
#
# Returns two hash maps:
# * The first, `finald`, gives the probability of ending in each possible state.
#
#       P(s_{observations.length} = s) = finald[s]
#
# * The second, `samples`, gives a sample drawn from those state sequences that
#   end in each possible state.
#
#       samples[s] ~ HMM(stated, transitionds, observationds) | observations, s_{observations.length} = s
def hmm_sample(stated, transitionds, observationds, observations)
	samples = Hash.new {|h,k| h[k] = [k]}

	# Make sure we get sane defaults if we access a key that doesn't exist.
	stated = Hash.new(0).update(stated)
	new_transitionds  = Hash.new {|h,k| h[k] = Hash.new(0)}
	new_observationds = Hash.new {|h,k| h[k] = Hash.new(0)}
	transitionds .each { |s,d| new_transitionds [s] = Hash.new(0).update(d) }
	observationds.each { |s,d| new_observationds[s] = Hash.new(0).update(d) }
	transitionds  = new_transitionds
	observationds = new_observationds
	# don't force the GC to hold onto these
	new_transitionds = nil
	new_observationds = nil

	observations.each do |o|
		# First update the probability of being in each state (and extend each
		# sample by one) using transitionds, ignoring the observation o.
		samplews = Hash.new {|h,k| h[k] = Hash.new(0)}
		transitionds.each do |s0,d|
			d.each do |s1,p|
				samplews[s1][Array.new(samples[s0]) << s1] = p*stated[s0]
			end
		end
		# transform_values is nicer, but we're in ruby 2.3, so...
		stated = Hash.new(0)
		samples = Hash.new {|h,k| h[k] = []}
		samplews.each do |s,w|
			stated[s] = w.inject(0) {|sum,(_,p)| sum+p}
			samples[s] = wchoose(w)
		end

		# Then condition on having seen o; the samples need not change.
		stated.each { |s,p| stated[s] = p*observationds[s][o] }
		renormalization_factor = stated.inject(0) {|s,(_,w)| s+w}
		stated.each { |s,w| stated[s] = w/renormalization_factor }
	end

	[stated, samples]
end

ChordProgressionRaw = {
	0 => { 1 => 0.15, 2 => 0.1, 3 => 0.25, 4 => 0.25, 5 => 0.2, 6 => 0.05 },
	1 => { 4 => 0.9, 6 => 0.1 },
	2 => { 1 => 0.2, 3 => 0.3, 5 => 0.5 },
	3 => { 0 => 0.05, 1 => 0.4, 4 => 0.4, 6 => 0.15 },
	4 => { 0 => 0.95, 5 => 0.05 },
	5 => { 1 => 0.7, 3 => 0.3 },
	6 => { 4 => 1 }
}

# Make sure that each state in an HMM transitions to itself with probability at
# least p.
def add_self_edges(transitionds, new_p)
	new_transitionds = {}
	not_new_p = 1-new_p
	transitionds.each do |s1, d|
		new_d = Hash.new(0)
		new_d[s1] = new_p
		d.each {|s0, p| new_d[s0] += not_new_p*p}
		new_transitionds[s1] = new_d
	end
	new_transitionds
end

SelfProbability = 0.5
ChordProgression = add_self_edges(ChordProgressionRaw, SelfProbability)
ChordElements = {
	0 => { 0 => 0.5, 2 => 0.225, 4 => 0.225, 6 => 0.04, 1 => 0.01 },
	1 => { 1 => 0.32, 3 => 0.32, 5 => 0.32, 0 => 0.03, 2 => 0.01 },
	2 => { 2 => 0.32, 4 => 0.32, 6 => 0.32, 1 => 0.03, 3 => 0.01 },
	3 => { 3 => 0.32, 5 => 0.32, 0 => 0.32, 2 => 0.04 },
	4 => { 4 => 0.16, 6 => 0.6, 1 => 0.16, 3 => 0.08 },
	5 => { 5 => 0.32, 0 => 0.32, 2 => 0.32, 4 => 0.03, 6 => 0.01 },
	6 => { 6 => 0.25, 1 => 0.25, 3 => 0.25, 5 => 0.25 }
}

def random_harmonization(melody)
	pitch_classes = (melody.drop(1) << 0).map {|n| n%7}
	chord_roots = hmm_sample({0=>1.0}, ChordProgression, ChordElements, pitch_classes)[1][0]
	chord_roots.take(chord_roots.length-1)
end

# Given a list of pairs, coalesce neighbors with equal first parts by summing
# their second parts.
def coalesce(arr)
	return Array.new arr if arr.length < 2
	result = [arr[0]]
	j = 0
	0.upto(arr.length - 2) do |i|
		if arr[i][0] != arr[i+1][0] then
			result << arr[i+1]
			j += 1
		else
			result[j][1] += arr[i+1][1]
		end
	end
	result
end

MaxTriadJump = 3

# We'll make our bass lines with a sort of binary search-like algorithm. Given
# a series of chord roots, and a starting and ending note, we'll choose a bass
# note for the middle of the chord progression, then recurse on the first and
# last half of the progression.
#
# How to choose the bass note for the middle? Eh... choose randomly from the
# (let's say) three closest triad notes on either side of the arithmetic mean of
# the start and stop points, weighted by the inverse of how far away they are
# from the start and stop.
def random_bassline(roots, start, stop)
	return [start, stop] if roots.length < 3
	mid_idx = roots.length / 2
	mid_root = roots[mid_idx]
	triad = Set.new [0,2,4]
	choices = {}

	candidate = ((start + stop) / 2.0).ceil
	while choices.length < MaxTriadJump do
		if triad.include?((candidate - mid_root) % 7) then
			choices[candidate] = 1.0 / ((candidate - start).abs + (candidate - stop).abs + 1)
		end
		candidate += 1
	end

	candidate = ((start + stop) / 2.0).floor
	while choices.length < 2*MaxTriadJump do
		if triad.include?((candidate - mid_root) % 7) then
			choices[candidate] = 1.0 / ((candidate - start).abs + (candidate - stop).abs + 1)
		end
		candidate -= 1
	end

	mid_note = wchoose(choices)
	lbass = random_bassline(roots.take(mid_idx+1), start, mid_note)
	rbass = random_bassline(roots.drop(mid_idx  ), mid_note, stop)
	lbass + rbass.drop(1)
end

# The notes of the various triads, clipped to a smallish range a tiny bit
# bigger than one octave.
ShortRangeTriadMembers = [
	[-7,-5,-3,0,2], # 0
	[-9,-6,-4,-2,1], # 1
	[-8,-5,-3,-1,2], # 2
	[-9,-7,-4,-2,0], # 3
	[-8,-6,-3,-1,1], # 4
	[-9,-7,-5,-2,0,2], # 5
	[-8,-6,-4,-1,1]  # 6
]

live_loop :melody do
	melody = random_melody
	beat_count = (melody.size/RhythmDensity).ceil
	rhythm = random_partition(beat_count, melody.size)
	0.upto(3) do
		in_thread do
			melody.zip(rhythm).each do |note,duration|
				play major(:c5, note), sustain: 0.125*duration-0.1, release: 0.1
				sleep 0.125*duration
			end
		end
		harmony = coalesce(random_harmonization(melody).zip(rhythm))
		in_thread do
			harmony.each do |root,duration|
				1.upto(2*duration) do
					play major(:c5, ShortRangeTriadMembers[root].choose), amp: 0.4, sustain: 0.11, release: 0.015
					sleep 0.0625
				end
			end
		end
		harmony_roots = harmony.map {|root,_| root}
		harmony_durations = harmony.map {|_,duration| duration}
		bassline = random_bassline(harmony_roots, 0, 0)
		# Funny edge case: the bass line always has at least two notes, but the
		# harmony may have just one chord. To compensate, we add a duration of
		# 0 that will get coalesced away in that case (and never observed in
		# other cases).
		coalesce(bassline.zip(harmony_durations + [0])).each do |note,duration|
			play major(:c5, note-14), amp: 1.5, sustain: 0.125*duration-0.1, release: 0.1
			sleep 0.125*duration
		end
	end
end
