require 'ostruct'

## Approach inspired in "Object-Level Analysis of PDF Files" (Tamir Hassan)
module Tabula

  MAX_CLUST_LINE_SPACING = 1.75 # 5524.pdf i-cite
  MIN_CLUST_LINE_SPACING = 0.25 # Baghdad problem! 30.07.08
  LINE_SPACING_TOLERANCE = 0.05

  module Graph
    class Edge
      attr_accessor :from, :to, :direction
      attr_writer :length, :font_size

      def initialize(from, to, direction)
        self.from = from
        self.to = to
        self.direction = direction
      end

      def physical_length
        case self.direction
        when :left
          self.from.left - self.to.right
        when :right
          self.to.left - self.from.right
        when :above
          self.from.top - self.to.bottom
        when :below
          self.to.top - self.from.bottom
        end
      end

      def length
        @length ||= self.physical_length / self.font_size
      end

      def font_size
        @font_size ||= from.average_font_size(to)
      end

      def horizontal?
        self.direction == :left || self.direction == :right
      end

      def vertical?
        self.direction == :above || self.direction == :below
      end

      # sorter edges (line spacing) BEFORE longer edges
      # smaller width difference BEFORE larger width difference
      # smaller font BEFORE larger font
      # same font size BEFORE differing font sizes
      def <=>(other)
        ae1 = self
        ae2 = other

        # TODO comment this if-branch - what does it do?
        if ae1.horizontal? and ae2.horizontal?
          length_ret_val = ((ae1.length - ae1.length) * 10.0).to_i
          if ae1.length.within(ae2.length, 0.1)
            length_ret_val = 0
          end
          return length_ret_val
        end

        if ae1.vertical? and ae2.horizontal?
          return 1
        end

        if ae1.horizontal? and ae2.vertical?
          return 1
        end

        # here comes the fun part
        ft1 = ae1.from; tt1 = ae1.to
        ft2 = ae2.from; tt2 = ae2.to

        sfs1 = ft1.same_font_size?(tt1)
        sfs2 = ft2.same_font_size?(tt2)

        if sfs1 and sfs2
          # smaller font/larger font
          if ft1.same_font_size?(ft2)
            # line spacing
            if ae1.vertical? and ae2.vertical?

              length_ret_val = ((ae1.length - ae2.length) * 10.0).to_i
              if ae1.length.within(ae2.length, 0.1)
                length_ret_val = 0
              end

              width_ret_val = 0; width1 = width2 = 0.0
              width1 = if ft1.width > tt1.width
                         ft1.width / tt1.width
                       else
                         tt1.width / ft1.width
                       end
              width2 = if ft2.width > tt2.width
                         ft2.width / tt2.width
                       else
                         tt2.width / ft2.width
                       end

              width_ret_val = if width1.within(width2, 0.1)
                                0
                              elsif width1 < width2
                                -1
                              else
                                1
                              end

              return length_ret_val == 0 ? width_ret_val : length_ret_val

            end # / ae1.vertical? and ae2.vertical?
          elsif ft1.font_size < ft2.font_size
            return -1
          else
            return 1
          end # ft1.same_font_size?(ft2)
        elsif sfs1
          return -1
        elsif sfs2
          return 1
        else
          return 0
        end

      end


      def to_h
        { :from => self.from,
          :to => self.to,
          :direction => self.direction,
          :length => self.length
        }
      end

      def to_json(options = {})
          to_h.to_json
      end
    end

    class Graph

      attr_accessor :vertices, :edges

      OPPOSITE = {
        :above => :below, :below => :above,
        :right => :left, :left => :right
      }

      def initialize(vertices)
        self.vertices = vertices
        self.edges = {}
      end

      def add_edge(u, v, direction)
        self.edges[u] = [] if self.edges[u].nil?
        self.edges[v] = [] if self.edges[v].nil?

        if !self.edges[u].find { |e| e.to == v }
          self.edges[u] << Edge.new(u, v, direction)
#          self.edges[v] << Edge.new(v, u, OPPOSITE[direction])
        end
      end

      def edges_list
        self.edges.map { |k, v| v}.flatten
      end


      # returns a json dict:
      # { 'vertices': <graph vertices indexed by its numeric id>,
      #   'edges':    <graph edges indexed by the numeric id of is 'from' vertex> }
      def to_json(options = {})
        {
          :vertices => self.vertices.inject({}) { |h, vertex|
            h[vertex.object_id] = vertex; h
          },
          :edges => self.edges.inject({}) { |h, (k, edges)|
            h[k.object_id] = edges.map { |e|
              e.to_h.merge!({ :from_id => e.from.object_id,
                              :to_id => e.to.object_id })
            }
            h
          },
          :sorted_edges => self.edges_list.sort # TODO delete this, probably
        }.to_json
      end

      def cluster_together(edge, cluster_from, cluster_to)
        text_from = edge.from; text_to = edge.to

        if edge.horizontal?
          if cluster_from.nil?
            cluster_from = Tabula::ZoneEntity.new
            cluster_from.texts << text_from
          end

          if cluster_to.nil?
            cluster_to = Tabula::ZoneEntity.new
            cluster_to.texts << text_from # TODO is this a bug in TextBlockSegmentation.java?
          end

          if cluster_from == cluster_to
            return false
          end

          # awful boolean trickery ahead (to avoid writing even more nested ifs)
          # TODO move inside new method. maybe graph.edges.closest_neighbour(direction) ??
          stub = OpenStruct.new({:to => nil})
          neighbours_from = [((self.edges[text_from]
                                 .select { |e| e.direction == :above } or [])
                                .sort_by { |e| e.to.midpoint[1] }
                                .last or stub).to,  # lowest neighbour above
                             ((self.edges[text_from]
                                 .select { |e| e.direction == :below } or [])
                                .sort_by { |e| e.to.midpoint[1] }
                                .first or stub).to # highest neighbour below
                            ]

          neighbours_to = [((self.edges[text_to]
                               .select { |e| e.direction == :above } or [])
                              .sort_by { |e| e.to.midpoint[1] }
                              .last or stub).to, # lowest neighbour above
                           ((self.edges[text_from]
                             .select { |e| e.direction == :below } or [])
                              .sort_by { |e| e.to.midpoint[1] }
                              .first or stub).to # highest neighbour below
                          ]

          closest_neighbour_from = closest_neighbour_to = nil

          # find closest neighbour of 'from' vertex
          if !neighbours_from[0].nil? and !neighbours_from[1].nil?
            distance_above = neighbours_from[0].y1 - text_from.y2
            distance_below = text_from.y1 - neighbours_from[1].y2
            closest_neighbour_from = if distance_above < distance_below
                                       neighbours_from[0]
                                     else
                                       neighbours_from[1]
                                     end
          elsif !neighbours_from[0].nil?
            closest_neighbour_from = neighbours_from[0]
          elsif !neighbours_from[1].nil?
            closest_neighbour_from = neighbours_from[1]
          end

          # find closest neighbour of 'to' vertex
          if !neighbours_to[0].nil? and !neighbours_to[1].nil?
            distance_above = neighbours_to[0].y1 - text_to.y2
            distance_below = text_to.y1 - neighbours_to[1].y2
            closest_neighbour_to = if distance_above < distance_below
                                       neighbours_to[0]
                                     else
                                       neighbours_to[1]
                                     end
          elsif !neighbours_to[0].nil?
            closest_neighbour_to = neighbours_to[0]
          elsif !neighbours_to[1].nil?
            closest_neighbour_to = neighbours_to[1]
          end

          # find closest neighbour
          closest_neighbour = nil; neighbour_distance = -1;
          if !closest_neighbour_from.nil? and !closest_neighbour_to.nil?
            distance_from = if closest_neighbour_from.midpoint[1] - text_from.midpoint[1]
                              text_from.y1 - closest_neighbour_from.y2
                            else
                              closest_neighbour_from.y1 - text_from.y2
                            end

            distance_to = if closest_neighbour_to.midpoint[1] < text_to.midpoint[1]
                            text_to.y1 - closest_neighbour_to.y2
                          else
                            closest_neighbour_to.y1 - text_to.y2
                          end

            closest_neighbour, neighbour_distance = if distance_from < distance_to
                                                      [closest_neighbour_from, distance_from]
                                                    else
                                                      [closest_neighbour_to, distance_to]
                                                    end
          elsif !closest_neighbour_from.nil?
            closest_neighbour = closest_neighbour_from
            distance_from = if closest_neighbour_from.midpoint[1] < text_from.midpoint[1]
                              text_from.y1 - closest_neighbour_from.y2
                            else
                              closest_neighbour_from.y1 - text_from.y2
                            end
            neighbour_distance = distance_from
          elsif !closest_neighbour_to.nil?
            closest_neighbour = closest_neighbour_to
            distance_to = if closest_neighbour_to.midpoint[1] < text_to.midpoint[1]
                              text_to.y1 - closest_neighbour_to.y2
                            else
                              closest_neighbour_to.y1 - text_to.y2
                            end
            neighbour_distance = distance_to
          end

          max_horiz_edge_width = 0.75
          if !(cluster_from.lines.size <= 2 || cluster_to.lines.size <= 2)
            max_horiz_edge_width = 0.85
          end

          if !(cluster_from.lines.size <= 1 || cluster_to.lines.size <= 1)
            max_horiz_edge_width = 1.0
          end

          same_base_line = text_from.y1.within(text_to.y1, [text_from.font_size, text_to.font_size].min * 0.2)
          unless same_base_line
            max_horiz_edge_width = 0.3
          end

          smallest_font_size = edge.from.font_size
          if edge.from.font_size > edge.to.font_size
            smallest_font_size = edge.to.font_size
          end

          horiz_gap = edge.physical_length / smallest_font_size
          if horiz_gap > max_horiz_edge_width
            return false
          end

          return true

        end # if edge.horizontal?

        # here come the vertical edges
        line_spacing = if edge.direction == :above
                         edge.to.y1 - edge.from.y1
                       else
                         edge.from.y1 - edge.to.y1
                       end

        line_spacing = line_spacing / edge.font_size

        unless text_from.same_font_size?(text_to)
          return false
        end

        if !(line_spacing <= MAX_CLUST_LINE_SPACING and line_spacing >= MIN_CLUST_LINE_SPACING)
          return false
        end

        if cluster_from.nil? and cluster_to.nil?
          return true
        elsif cluster_from.nil?
          if cluster_to.line_spacing == 0.0 or
              line_spacing.within(cluster_to.line_spacing, LINE_SPACING_TOLERANCE)
            return true
          end
        elsif cluster_to.nil?
          if cluster_from.line_spacing == 0.0 or
            line_spacing.within(cluster_from.line_spacing, LINE_SPACING_TOLERANCE)
            return true
          end
        else
          if cluster_from == cluster_to
            return false
          end
          same_line_spacing = cluster_from.line_spacing.within(cluster_to.line_spacing,
                                                             LINE_SPACING_TOLERANCE)
          return same_line_spacing && line_spacing.within(cluster_from.line_spacing, LINE_SPACING_TOLERANCE) && line_spacing.within(cluster_to.line_spacing, LINE_SPACING_TOLERANCE)
        end

        return false
      end

      # "factory" method for graphs from a list of text_elements
      def self.make_graph(text_elements)
        horizontal = text_elements.sort_by { |mp| mp.midpoint[0] }
        vertical   = text_elements.sort_by { |mp| mp.midpoint[1] }

        graph = Graph.new(text_elements)

        text_elements.each do |te|

          hi = horizontal.index(te); vi = vertical.index(te)

          puts "TE: '#{te.text}' (#{te.left}, #{te.top})"

          # look for first neighbour to the left
          (hi-1).downto(0) do |i|
            if te.vertically_overlaps?(horizontal[i]) and !te.horizontally_overlaps?(horizontal[i])
#              puts "  FOUND LEFT: '#{horizontal[i].text}' (#{horizontal[i].left}, #{horizontal[i].top})"
              graph.add_edge(te, horizontal[i], :left)
              break
            end
          end

          # look for first neighbour to the right
          (hi+1).upto(horizontal.length - 1) do |i|
            if te.vertically_overlaps?(horizontal[i]) and !te.horizontally_overlaps?(horizontal[i])

              graph.add_edge(te, horizontal[i], :right)
              break
            end
          end

          # look for first neighbour above
          (vi-1).downto(0) do |i|
            if te.horizontally_overlaps?(vertical[i]) and !te.vertically_overlaps?(vertical[i])
              graph.add_edge(te, vertical[i], :above)
              break
            end
          end

          # look for first neighbour below
          (vi+1).upto(vertical.length - 1) do |i|
            if te.horizontally_overlaps?(vertical[i]) and !te.vertically_overlaps?(vertical[i])
              graph.add_edge(te, vertical[i], :below)
              break
            end
          end
        end

        return graph

      end
    end

    ##
    # swallow items!
    # 'principle of rectangular containment'
    def self.swallow(l1, l2, items, cluster_hash)

      temp = Tabula::ZoneEntity.new
      l1.each { |l| temp.texts <<  l }; l2.each { |l| temp.texts <<  l }
      swallowed_items = []
      loop = true
      while loop do
        swallowed_items = items.select { |i|
          i.vertically_overlaps?(temp) and i.horizontally_overlaps?(temp)
        }

        new_items = []

        swallowed_items.each do |gs|
          unless cluster_hash[gs].nil?
            new_items += cluster_hash.texts
          end
        end

        swallowed_items += new_items
        swallowed_items.uniq!

        if temp.texts.size == swallowed_items.texts.size
          # list didn't grow, nothing swallowed
          loop = false
        end

        swallowed_items.each { |si| temp.texts << si }
      end

      return swallowed_items

    end

    # Ported from PageSegmenter.java
    def self.ordered_edge_cluster(graph, max_iterations, cluster_hash)
      retval = [] # list of Clusters (ZoneEntity)
      unused_segments = [graph.vertices.sort_by(&:y1)]
      all_segments = [graph.vertices.sort_by(&:y1)]
      priority_edges = []
      all_edges = []

      graph.edges.each do |k, edges|
        edges.each { |edge|
          e = edge.clone
          priority_edges << e
          all_edges << e
        }
      end

      priority_edges.sort!

      while priority_edges.size > 0
        ae = priority_edges.delete_at(0)

        text_from = ae.from; text_to = ae.to
        line_spacing = ae.length

        if cluster_hash[text_from].nil? and cluster_hash[text_to].nil? and
            graph.cluster_together(edge, nil, nil)
          swallowed_segments = swallow([text_from], [text_to], all_segments, cluster_hash)

          unless ae.vertical? or (ae.horizontal? and swallowed_segments.size <= 2)
            next
          end

          newc = Tabula::ZoneEntity.new
          swallowed_segments.each { |ss| newc.texts << ss }

          unless newc.valid_cluster?
            next
          end

          # TODO update hashes - WTF does this method do?
        elsif cluster_hash[text_from].nil?

        elsif cluster_hash[text_to].nil?
        else # both segments already used, merge

        end

        if priority_edges.size == 0


        end

      end






    end

    def self.merge_text_elements(text_elements)
      current_word_index = i = 0
      char1 = text_elements[i]

#      require 'debugger'; debugger

      while i < text_elements.size-1 do

        char2 = text_elements[i+1]
        puts "#{text_elements[current_word_index].text}, #{char1}, #{char2}"

        next if char2.nil? or char1.nil?



        if text_elements[current_word_index].should_merge?(char2)
          text_elements[current_word_index].merge!(char2)
          char1 = char2
          text_elements[i+1] = nil
        else
          current_word_index = i+1
        end
        i += 1
      end

      text_elements.compact!

    end

  end
end



if __FILE__ == $0
  require_relative '../tabula_web.rb'
  text_elements = merge_text_elements(get_text_elements('4d9fd418460b798686c042084092f15ddc8ccddb', 1, 23.375, 252.875, 562.0625, 691.6875))
  puts text_elements.inspect
  graph = Tabula::Graph::Graph.make_graph(text_elements)
#  puts graph.to_json
end
