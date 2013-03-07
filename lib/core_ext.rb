# Extensions to core classes

class Numeric

  def within(other, tolerance)
    other > self - tolerance and other < self + tolerance
  end

end


class Foo
  attr_accessor :caca, :pimba
  def initialize
    self.caca = []
    self.pimba = 'pimba!'

    parent = self
    self.caca.define_singleton_method(:<<, proc { |arg|
                                        self.push(arg)
                                        puts parent.pimba, arg
                                      })


  end

end
