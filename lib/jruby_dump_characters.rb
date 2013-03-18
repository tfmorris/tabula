# VERY DIRTY SCRIPT
# TODO refactor. we should get rid of the XML intermediate step, anyway.
require 'java'

java_import org.apache.pdfbox.pdfparser.PDFParser
java_import org.apache.pdfbox.pdmodel.PDDocument
java_import org.apache.pdfbox.util.PDFTextStripper
java_import org.apache.pdfbox.util.PDFStreamEngine
java_import org.apache.pdfbox.pdfviewer.PageDrawer
java_import org.apache.pdfbox.util.operator.OperatorProcessor

java_import java.awt.image.BufferedImage
java_import java.awt.Color
java_import java.awt.geom.PathIterator
java_import java.awt.geom.Point2D
java_import java.awt.geom.Rectangle2D

import java.awt.geom.GeneralPath

# java_import java.io.File

# TODO: reuse Tabula::ZoneEntity
class GenericSegment < Struct.new(:x1, :y1, :x2, :y2)
  alias_method :lower_left_x, :x1
  alias_method :lower_left_y, :y1
  alias_method :upper_right_x, :x2
  alias_method :upper_right_y, :y2

  def initialize(*args)
    super(*args)
    # correct negative dimensions
    if self.x1 > self.x2
      temp = self.x1
      self.x1 = self.x2
      self.x2 = temp
    end

    if self.y1 > self.y2
      temp = self.y1
      self.y1 = self.y2
      self.y2 = temp
    end
  end

  def to_xml
    attrs = [:x1, :x2, :y1, :y2].map { |k|
      "#{k.to_s}=\"#{self.send(k)}\""
    }.join(' ')
    "<#{self.class} #{attrs} />"
  end

  def rotate(*args)
    if args.size == 3

      pointX, pointY, amount = args

      px1 = self.x1 - pointX; px2 = self.x2 - pointX
      py1 = self.y1 - pointY; py2 = self.y2 - pointY

      if (amount == 90 || amount == -270)
        self.x1 = pointX - py2; self.x2 = pointX - py1;
        self.y1 = pointY + px1; y2 = pointY + px2;
      elsif (amount == 270 || amount == -90)
        self.x1 = pointX + py1; self.x2 = pointX + py2;
        self.y1 = pointY - px2; self.y2 = pointY - px1;
      end
    elsif args.size == 1
      page = args.first
      mediaBox = page.getMediaBox
      if !page.getRotation.nil?
        # if self.class.to_s == 'RectSegment'
        #   require 'ruby-debug'; debugger
        # end
        rotate(mediaBox.getLowerLeftX, mediaBox.getLowerLeftY, page.getRotation);
        if (page.getRotation == 90 || page.getRotation == -270)
          self.x1 = x1 + mediaBox.getHeight();
          self.x2 = x2 + mediaBox.getHeight();
        elsif (page.getRotation() == 270 || page.getRotation() == -90)
          self.y1 = y1 + mediaBox.getWidth();
          self.y2 = y2 + mediaBox.getWidth();
        end
      end
    end
  end
end

class LineSegment < GenericSegment
end

class RectSegment < GenericSegment

  ##
  # returns an array of the component lines of this rectangle
  def to_lines
    raise "TODO: Not Implemented!"
  end

end

$page_contents = []
$current_page = 0
$fonts = Hash.new({})
$page_fonts = Hash.new({})

# hack into PDFStreamEngine and 'publish' private fields `operators` and `page`
# bad bad, not good
module Java::OrgApachePdfboxUtil
  class PDFStreamEngine
    field_accessor :operators, :page
  end
end

# PDF Operators
class MoveToOperator < org.apache.pdfbox.util.operator.OperatorProcessor
  def process(operator, arguments)

    drawer = self.context
    x, y = arguments[0], arguments[1]

    drawer.lineSubPaths << drawer.linePath
    newPath = java.awt.geom.GeneralPath.new
    ppos = drawer.TransformedPoint(x.doubleValue, y.doubleValue)

    newPath.moveTo(ppos.getX, ppos.getY)
    drawer.linePath = newPath
    drawer.simple_move_to!(x.floatValue, y.floatValue)
  end
end

class LineToOperator < org.apache.pdfbox.util.operator.OperatorProcessor
  def process(operator, arguments)
    drawer = self.context
    x, y = arguments[0], arguments[1]
    ppos = drawer.TransformedPoint(x.doubleValue, x.doubleValue)
    drawer.linePath.lineTo(ppos.getX, ppos.getY)
    drawer.simple_line_to!(x.floatValue, y.floatValue)
  end
end

# usually, ruling lines in tables are thin rectangles
# hence the need to scan for rectangles
class AppendRectangleToPathOperator < org.apache.pdfbox.util.operator.OperatorProcessor
  def process(operator, arguments)
    drawer = self.context
    x, y, w, h = arguments.to_array
    finalX, finalY, finalW, finalH = x.floatValue, y.floatValue, w.floatValue, h.floatValue
    ppos = drawer.TransformedPoint(finalX, finalY)
    psize = drawer.ScaledPoint(finalW, finalH)

    finalY = ppos.getY - psize.getY
    if finalY < 0
      finalY = 0
    end

    rect = java.awt.geom.Rectangle2D::Double.new(ppos.getX, finalY, psize.getX, psize.getY)
    drawer.linePath.reset
    drawer.linePath.append(rect, false)

    drawer.new_path!
    drawer.simple_add_rect!(ppos.get_x, finalY, psize.getX, psize.getY)
  end
end


class DummyOperatorProcessor < org.apache.pdfbox.util.operator.OperatorProcessor

  attr_accessor :operator

  def initialize(operator)
    super()
    self.operator = operator
  end

  def process(operator, arguments)
    puts "process: #{self.operator.inspect} - #{arguments.inspect}"
  end

end


class TextExtractor < org.apache.pdfbox.util.PDFTextStripper

  attr_accessor :contents, :fonts
  attr_accessor :lineSubPaths, :linePath, :lineList, :rectList, :currentLines, :currentRects, :linesToAdd,  :rectsToAdd, :strokingColor
  attr_accessor :newPath, :pathContainsCurve, :pathBeginSet, :pathClosed
  attr_accessor :currentX, :currentY

  def initialize
    super
    self.setSortByPosition(true)
    self.clear!

    registerOperatorProcessor('m', MoveToOperator.new)
    registerOperatorProcessor('re', AppendRectangleToPathOperator.new)
    registerOperatorProcessor('l', LineToOperator.new)
  end

  def clear!
    self.fonts = {}
    self.contents = ''
    self.lineSubPaths = []
    self.linePath = java.awt.geom.GeneralPath.new
    self.lineList = []
    self.rectList = []
    self.currentLines = []
    self.currentRects = []
    self.linesToAdd = []
    self.rectsToAdd = []
    self.newPath = false
    self.currentX = -1; self.currentY = -1
  end

  def new_path!
    self.linesToAdd += currentLines
    self.rectsToAdd += currentRects
    self.newPath = true
    self.pathContainsCurve = false
    self.pathBeginSet = false
    self.pathClosed = false
    self.currentLines = []
    self.currentRects = []
  end

  def simple_move_to!(x, y)
    ppos = self.TransformedPoint(x, y)
    self.currentX, self.currentY = ppos.getX, ppos.getY
  end

  def simple_line_to!(x, y)
    # TODO include color
    # comp = strokingColor.getRGBColorComponents(nil)
    pto = self.TransformedPoint(x, y)

    newLine = LineSegment.new(currentX, currentY, pto.getX, pto.getY)
    newLine.rotate(self.page)
    self.linesToAdd << newLine
    self.currentX = pto.getX; self.currentY = pto.getY
    puts "line from: (#{newLine.x1}, #{newLine.y1}) -> (#{newLine.x2}, #{newLine.y2})"
  end

  def simple_add_rect!(x, y, w, h)
    # TODO include color
    # comp = getStrokingColor.getRGBColorComponents(nil)
    newRect = RectSegment.new(x, x+w, y, y+h)
    newRect.rotate(self.page)
    self.rectsToAdd << newRect
    self.currentX = x
    self.currentY = y
    #puts "rectangle (#{newRect.x1}, #{newRect.y1}) -> (#{newRect.x2}, #{newRect.y2})"
    puts newRect.to_xml
  end

  ##
  # get current page size
  def pageSize
    self.page.findMediaBox.createDimension
  end

  ##
  # fix the Y coordinate based on page rotation
  def fixY(x, y)
    pageSize.getHeight - y
  end

  def ScaledPoint(*args)
    x, y = args[0], args[1]

    # if scale factor not provided, get it from current transformation matrix
    if args.size == 2
      ctm = getGraphicsState.getCurrentTransformationMatrix
      at = ctm.createAffineTransform
      scaleX = at.getScaleX; scaleY = at.getScaleY
    else
      scaleX = args[2]; scaleY = args[3]
    end

    finalX = 0.0;
    finalY = 0.0;

    if scaleX > 0
      finalX = x * scaleX;
    end
    if scaleY > 0
      finalY = y * scaleY;
    end

    return java.awt.geom.Point2D::Double.new(finalX, finalY);

  end


  def TransformedPoint(x, y)
    scaleX = 0.0;
    scaleY = 0.0;
    transX = 0.0;
    transY = 0.0;

    finalX = x;
    finalY = y;

    # Get the transformation matrix
    ctm = getGraphicsState().getCurrentTransformationMatrix();
    at = ctm.createAffineTransform();

    scaleX = at.getScaleX();
    scaleY = at.getScaleY();
    transX = at.getTranslateX();
    transY = at.getTranslateY();

    pscale = self.ScaledPoint(finalX, finalY, scaleX, scaleY);
    finalX = pscale.getX();
    finalY = pscale.getY();

    finalX += transX;
    finalY += transY;

    finalY = fixY( finalX, finalY );
    finalY -= 0.6;

    java.awt.geom.Point2D::Double.new(finalX, finalY);

  end


  def processTextPosition(text)
    #    return if text.getCharacter == ' '

    # text_font = text.getFont
    # text_size = text.getFontSize
    # font_plus_size = self.fonts.select { |k, v| v == text_font }.first.first + "-" + text_size.to_i.to_s

    # $fonts[$current_page].merge!({
    #   font_plus_size => { :family => text_font.getBaseFont, :size => text_size }
    # })

    #    $page_contents[$current_page] += "  <text top=\"%.2f\" left=\"%.2f\" width=\"%.2f\" height=\"%.2f\" font=\"#{font_plus_size}\" dir=\"#{text.getDir}\">#{text.getCharacter}</text>\n" % [text.getYDirAdj - text.getHeightDir, text.getXDirAdj, text.getWidthDirAdj, text.getHeightDir]

    self.contents += "  <text top=\"%.2f\" left=\"%.2f\" width=\"%.2f\" height=\"%.2f\" fontsize=\"%.2f\" dir=\"%s\"><![CDATA[%s]]></text>\n" % [text.getYDirAdj - text.getHeightDir, text.getXDirAdj, text.getWidthDirAdj, text.getHeightDir, text.getFontSize, text.getDir, text.getCharacter]

  end

end


def print_text_locations(pdf_file_name, output_directory)
  pdf_file = PDDocument.loadNonSeq(java.io.File.new(pdf_file_name), nil)
  all_pages = pdf_file.getDocumentCatalog.getAllPages
  extractor = TextExtractor.new

  index_file = File.new(output_directory + "/pages.xml", 'w')
  index_file.puts <<-index_preamble
  <?xml version="1.0" encoding="UTF-8"?>
  <index>
  index_preamble

  all_pages.each_with_index do |page, i|

    contents = page.getContents
    next if contents.nil?

    outfile = File.new(output_directory + "/page_#{i + 1}.xml", 'w')

    extractor.clear!
    extractor.processStream(page, page.findResources, contents.getStream)

    preamble = <<-xmlpreamble
<?xml version="1.0" encoding="UTF-8"?>
<pdf2xml producer="pdfbox" version="1.7.5">
    xmlpreamble
    outfile.puts preamble
    page_tag = "<page number=\"#{i+1}\" position=\"absolute\" top=\"0\" left=\"0\" height=\"#{page.findCropBox.getHeight}\" width=\"#{page.findCropBox.getWidth}\" rotation=\"#{page.getRotation}\""
    outfile.puts page_tag + ">"

    # # $fonts[i].each { |font_id, font|
    # #   puts "  <fontspec id=\"#{font_id}\" size=\"#{font[:size]}\" family=\"#{font[:family]}\" color=\"#000000\"/>"
    # # }

    outfile.puts extractor.contents
    outfile.puts "</page>"
    outfile.puts "</pdf2xml>"
    outfile.close

    # graphic elements (lines and rects)
    # TODO refactor this
    outfile = File.new(output_directory + "/page_#{i + 1}_graphics.xml", 'w')
    outfile.puts preamble
    outfile.puts page_tag + ">"
    (extractor.linesToAdd + extractor.rectsToAdd).each do |s|
      outfile.puts s.to_xml
    end
    outfile.puts "</page></pdf2xml>"

    index_file.puts page_tag + "/> "

    STDERR.puts "converted #{i+1}/#{all_pages.size}"

  end

  index_file.puts "</index>"
  index_file.close
  pdf_file.close

end

if __FILE__ == $0

  print_text_locations(ARGV[0], ARGV[1])

end
