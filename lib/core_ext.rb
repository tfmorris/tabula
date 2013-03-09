# Extensions to core classes

class Numeric
  def within(other, tolerance)
    other > self - tolerance && other < self + tolerance
  end
end
