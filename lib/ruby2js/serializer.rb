module Ruby2JS
  class Token < String
    attr_accessor :loc
    attr_accessor :ast

    def initialize(string, ast)
      super(string.to_s)
      @ast = ast
      @loc = ast.location if ast
    end
  end

  class Line < Array
    attr_accessor :indent

    def initialize(*args)
      super(args)
      @indent = 0
    end

    def comment?
      first = find {|token| !token.empty?}
      first and first.start_with? '//'
    end

    def empty?
      all? {|line| line.empty?}
    end

    def to_s
      if empty?
        ''
      elsif ['case ', 'default:'].include? self[0]
        ' ' * ([0,indent-2].max) + join
      else
        ' ' * indent + join
      end
    end
  end

  class Serializer
    attr_reader :timestamps

    def initialize
      @sep = '; '
      @nl = ''
      @ws = ' '

      @width = 80
      @indent = 0

      @lines = [Line.new]
      @line = @lines.last
      @timestamps = {}
    end

    def timestamp(file)
      @timestamps[file] = File.mtime(file) if file and File.exist?(file)
    end

    def uptodate?
      return false if @timestamps.empty?
      return @timestamps.all? {|file, mtime| File.mtime(file) == mtime}
    end

    def mtime
      return Time.now if @timestamps.empty?
      return @timestamps.values.max
    end

    def enable_vertical_whitespace
      @sep = ";\n"
      @nl = "\n"
      @ws = @nl
      @indent = 2
    end

    # indent multi-line parameter lists, array constants, blocks
    def reindent
      indent = 0
      @lines.each do |line|
        first = line.find {|token| !token.empty?}
        if first
          last = line[line.rindex {|token| !token.empty?}]
          indent -= @indent if ')}]'.include? first[0]
          line.indent = indent
          indent += @indent if '({['.include? last[-1]
        else
          line.indent = indent
        end
      end
    end

    # add horizonal (indentation) and vertical (blank lines) whitespace
    def respace
      reindent

      (@lines.length-3).downto(0) do |i|
        if
          @lines[i].length == 0
        then
          @lines.delete i
        elsif
          @lines[i+1].comment? and not @lines[i].comment?
        then
          # before a comment
          @lines.insert i+1, Line.new
        elsif
          @lines[i].indent == @lines[i+1].indent and 
          @lines[i+1].indent < @lines[i+2].indent and
          not @lines[i].comment?
        then
          # start of indented block
          @lines.insert i+1, Line.new
        elsif
          @lines[i].indent > @lines[i+1].indent and 
          @lines[i+1].indent == @lines[i+2].indent and
          not @lines[i+2].empty?
        then
          # end of indented block
          @lines.insert i+2, Line.new
        end
      end
    end

    # add a single token to the current line
    def put(string)
      unless String === string and string.include? "\n"
        @line << Token.new(string, @ast)
      else
        parts = string.split("\n")
        @line << Token.new(parts.shift, @ast)
        @lines += parts.map {|part| Line.new(Token.new(part, @ast))}
        @lines << Line.new if string.end_with?("\n")
        @line = @lines.last
      end
    end

    # add a single token to the current line and then advance to next line
    def puts(string)
      unless String === string and string.include? "\n"
        @line << Token.new(string, @ast)
      else
        put string
      end

      @line = Line.new
      @lines << @line
    end

    # advance to next line and then add a single token to the current line
    def sput(string)
      unless String === string and string.include? "\n"
        @line = Line.new(Token.new(string, @ast))
        @lines << @line
      else
        @line = Line.new
        @lines << @line
        put string
      end
    end

    # current location: [line number, token number]
    def output_location
      [@lines.length-1, @line.length]
    end

    # insert a line into the output
    def insert(mark, line)
      if mark.last == 0
        @lines.insert(mark.first, Line.new(Token.new(line.chomp, @ast)))
      else
        @lines[mark.first].insert(mark.last, Token.new(line, @ast))
      end
    end

    # capture (and remove) tokens from the output stream
    def capture(&block)
      mark = output_location
      block.call
      lines = @lines.slice!(mark.first+1..-1)
      @line = @lines.last

      if lines.empty?
        lines = [@line.slice!(mark.last..-1)]
      elsif @line.length != mark.last
        lines.unshift @line.slice!(mark.last..-1), [@ws]
      end

      lines.map(&:join).join(@nl)
    end

    # wrap long statements in curly braces
    def wrap
      puts '{'
      mark = output_location
      yield

      if
        @lines.length > mark.first+1 or
        @lines[mark.first-1].join.length + @line.join.length >= @width
      then
        sput '}'
      else
        @line = @lines[mark.first-1]
        @line[-1..-1] = @lines.pop
      end
    end

    # compact small expressions into a single line
    def compact
      mark = output_location
      yield
      return unless @lines.length - mark.first > 1
      return if @lines[mark.first..-1].any? do |line|
        line.first.to_s.start_with? '//'
      end

      len = @lines[mark.first..-1].map { |line|
        line.map(&:length).reduce(&:+).to_i + 1
      }.reduce(&:+).to_i

      if len < @width - 10
        lines = @lines.slice!(mark.first..-1)
        @line = Line.new
        lines.each_with_index do |line, index|
          @line << ' ' unless index <= 1 or index >= lines.length-1
          @line.push *line
        end
        @lines.push @line
      end
    end

    # return the output as a string
    def to_s
      respace if @indent > 0
      @lines.map(&:to_s).join(@nl)
    end

    def to_str
      to_s
    end

    def +(value)
      to_s+value
    end

    BASE64 = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/'

    # https://docs.google.com/document/d/1U1RGAehQwRypUTovF1KRlpiOFze0b-_2gc6fAH0KY0k/edit
    def vlq(*mark)
      if @mark[0] == mark[0]
        return if @mark[-3..-1] == mark[-3..-1]
        @mappings << ',' unless @mappings == ''
      end

      while @mark[0] < mark[0]
        @mappings << ';'
        @mark[0] += 1
        @mark[1] = 0
      end

      diffs = mark.zip(@mark).map {|a,b| a-b}
      @mark = mark

      diffs[1..4].each do |diff|
        if diff < 0
          data = (-diff << 1) + 1
        else
          data = diff << 1
        end

        encoded = ''

        begin
          digit = data & 0b11111
          data >>= 5
          digit |= 0b100000 if data > 0
          encoded << BASE64[digit]
        end while data > 0

        @mappings << encoded
      end
    end

    def sourcemap
      respace if @indent > 0

      @mappings = ''
      sources = []
      @mark = [0, 0, 0, 0, 0]

      @lines.each_with_index do |line, row|
        col = line.indent
        line.each do |token|
          if token != ' ' and token.loc
            pos = token.loc.expression.begin_pos

            buffer = token.loc.expression.source_buffer
            source_index = sources.index(buffer)
            if not source_index
              source_index = sources.length
              timestamp buffer.name
              sources << buffer
            end

            split = buffer.source[0...pos].split("\n")
            vlq row, col, source_index, split.length-1, split.last.to_s.length
          end
          col += token.length
        end
      end

      {
        version: 3,
        file: @ast.loc.expression.source_buffer.name,
        sources: sources.map(&:name),
        mappings: @mappings
      }
    end
  end
end
