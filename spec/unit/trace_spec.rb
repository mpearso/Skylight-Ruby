require "spec_helper"

# This lives here because it depends on the native agent
module Skylight
  describe Trace, :http, :agent do
    before :each do
      clock.tick = 100_000_000
      start!
    end

    after :each do
      Skylight.stop!
    end

    it "tracks the span when it is finished" do
      trace = Skylight.trace "Rack", "app.rack.request"
      clock.skip 0.1
      a = trace.instrument "foo"
      clock.skip 0.1
      trace.done(a)
      trace.submit

      server.wait resource: "/report"

      expect(spans.count).to eq(2)
      expect(spans[0].event.category).to eq("app.rack.request")
      expect(spans[1].event.category).to eq("foo")
      expect(spans[0].started_at).to eq(0)
      expect(spans[1].started_at).to eq(1000)
    end

    it "builds the trace" do
      trace = Skylight.trace "Rack", "app.rack.request"
      a = trace.instrument "cat1", foo: "bar"
      clock.skip 0.001
      b = trace.instrument "cat2"
      c = trace.instrument "cat3"
      clock.skip 0.001
      trace.record "cat4"
      clock.skip 0.002
      trace.record "cat5"
      trace.done(c)
      clock.skip 0.003
      trace.done(b)
      clock.skip 0.002
      trace.done(a)
      trace.submit

      server.wait resource: "/report"

      expect(spans.count).to eq(6)

      expect(spans[0].event.category).to eq("app.rack.request")
      expect(spans[0].started_at).to     eq(0)
      expect(spans[0].parent).to         eq(nil)
      expect(spans[0].duration).to       eq(90)

      expect(spans[1].event.category).to eq("cat1")
      expect(spans[1].started_at).to     eq(0)
      expect(spans[1].parent).to         eq(0)
      expect(spans[1].duration).to       eq(90)

      expect(spans[2].event.category).to eq("cat2")
      expect(spans[2].started_at).to     eq(10)
      expect(spans[2].parent).to         eq(1)
      expect(spans[2].duration).to       eq(60)

      expect(spans[3].event.category).to eq("cat3")
      expect(spans[3].started_at).to     eq(0)
      expect(spans[3].parent).to         eq(2)
      expect(spans[3].duration).to       eq(30)

      expect(spans[4].event.category).to eq("cat4")
      expect(spans[4].started_at).to     eq(10)
      expect(spans[4].parent).to         eq(3)
      expect(spans[4].duration).to       eq(0)

      expect(spans[5].event.category).to eq("cat5")
      expect(spans[5].started_at).to     eq(30)
      expect(spans[5].parent).to         eq(3)
      expect(spans[5].duration).to       eq(0)
    end

    it "force closes any open span on build" do
      begin
        original_raise_on_error = ENV["SKYLIGHT_RAISE_ON_ERROR"]
        ENV["SKYLIGHT_RAISE_ON_ERROR"] = nil

        trace = Skylight.trace "Rack", "app.rack.request"
        trace.instrument "foo"
        clock.skip 0.001
        trace.submit

        server.wait resource: "/report"

        expect(spans.count).to eq(2)
        expect(spans[1].event.category).to eq("foo")
        expect(spans[1].started_at).to eq(0)
        expect(spans[1].duration).to eq(10)

        expect(spans[0].event.category).to eq("app.rack.request")
      ensure
        ENV["SKYLIGHT_RAISE_ON_ERROR"] = original_raise_on_error
      end
    end

    it "marks broken for invalid span nesting" do
      begin
        original_raise_on_error = ENV["SKYLIGHT_RAISE_ON_ERROR"]
        ENV["SKYLIGHT_RAISE_ON_ERROR"] = nil

        trace = Skylight.trace "Rack", "app.rack.request"
        a = trace.instrument "foo"
        clock.skip 0.1
        _b = trace.instrument "bar"
        clock.skip 0.1
        trace.done(a)

        expect(trace).to be_broken
      ensure
        ENV["SKYLIGHT_RAISE_ON_ERROR"] = original_raise_on_error
      end
    end

    it "closes any spans that were not properly closed" do
      begin
        original_raise_on_error = ENV["SKYLIGHT_RAISE_ON_ERROR"]
        ENV["SKYLIGHT_RAISE_ON_ERROR"] = nil

        trace = Skylight.trace "Rack", "app.rack.request"
        trace.instrument "foo"
        clock.skip 0.1
        trace.instrument "bar"
        clock.skip 0.1
        a = trace.instrument "baz"
        clock.skip 0.1
        trace.done(a)
        clock.skip 0.1
        trace.submit

        server.wait resource: "/report"

        expect(spans.count).to eq(4)

        expect(spans[0].event.category).to eq("app.rack.request")
        expect(spans[0].duration).to       eq(4000)

        expect(spans[1].event.category).to eq("foo")
        expect(spans[1].duration).to       eq(4000)

        expect(spans[2].event.category).to eq("bar")
        expect(spans[2].duration).to       eq(3000)

        expect(spans[3].event.category).to eq("baz")
        expect(spans[3].duration).to       eq(1000)
      ensure
        ENV["SKYLIGHT_RAISE_ON_ERROR"] = original_raise_on_error
      end
    end

    it "mutes child span instrumentation when specified" do
      trace = Skylight.trace "Rack", "app.rack.request"
      a = trace.instrument "foo", nil, nil, { mute_children: true }

      clock.skip 0.1
      b = trace.instrument "bar"
      clock.skip 0.1
      c = trace.instrument "baz"
      clock.skip 0.1
      expect { trace.done(a) }.to change { trace.muted? }.from(true).to(false)
      d = trace.instrument "wibble"
      clock.skip 0.1
      e = trace.instrument "wobble"
      clock.skip 0.1
      f = trace.instrument "wubble"
      clock.skip 0.1
      [f, e, d].each { |span| trace.done(span) }
      trace.submit

      server.wait resource: "/report"

      expect(spans.count).to eq(5)
      expect(spans.map{ |x| x.event.category }).to eq(["app.rack.request", "foo", "wibble", "wobble", "wubble"])
      expect(b).to be_nil
      expect(c).to be_nil
    end


    it "cleans up current_trace when broken" do
      begin
        original_raise_on_error = ENV["SKYLIGHT_RAISE_ON_ERROR"]
        ENV["SKYLIGHT_RAISE_ON_ERROR"] = nil

        trace = Skylight.trace "Rack", "app.rack.request"
        a = trace.instrument "foo"
        clock.skip 0.1
        _b = trace.instrument "bar"
        clock.skip 0.1
        # Force out of order
        trace.done(a)

        expect(Skylight.instrumenter.current_trace).to eq(trace)
        trace.submit
        expect(Skylight.instrumenter.current_trace).to be_nil
      ensure
        ENV["SKYLIGHT_RAISE_ON_ERROR"] = original_raise_on_error
      end
    end

    it "tracks the title" do
      trace = Skylight.trace "Rack", "app.rack.request"
      a = trace.instrument "foo", "How a foo is formed?"
      trace.record :bar, "How a bar is formed?"
      trace.done(a)
      trace.submit

      server.wait resource: "/report"

      expect(spans[1].event.title).to eq("How a foo is formed?")
      expect(spans[2].event.title).to eq("How a bar is formed?")
    end

    it "tracks the description" do
      trace = Skylight.trace "Rack", "app.rack.request"
      a = trace.instrument "foo", "FOO", "How a foo is formed?"
      trace.record :bar, "BAR", "How a bar is formed?"
      trace.done(a)
      trace.submit

      server.wait resource: "/report"

      expect(spans[1].event.title).to       eq("FOO")
      expect(spans[1].event.description).to eq("How a foo is formed?")
      expect(spans[2].event.title).to       eq("BAR")
      expect(spans[2].event.description).to eq("How a bar is formed?")
    end

    it "limits unique descriptions" do
      original_raise_on_error = ENV["SKYLIGHT_RAISE_ON_ERROR"]
      ENV["SKYLIGHT_RAISE_ON_ERROR"] = nil
      begin
        trace = Skylight.trace "Rack", "app.rack.request"

        expect(Skylight.instrumenter).to receive(:limited_description).
          at_least(:once).
          with(any_args).
          and_return(Instrumenter::TOO_MANY_UNIQUES)

        a = trace.instrument "foo", "FOO", "How a foo is formed?"
        trace.record :bar, "BAR", "How a bar is formed?"
        trace.done(a)
        trace.submit

        server.wait resource: "/report"

        expect(spans[1].event.title).to       eq("FOO")
        expect(spans[1].event.description).to eq(Instrumenter::TOO_MANY_UNIQUES)
        expect(spans[2].event.title).to       eq("BAR")
        expect(spans[2].event.description).to eq(Instrumenter::TOO_MANY_UNIQUES)
      ensure
        ENV["SKYLIGHT_RAISE_ON_ERROR"] = original_raise_on_error
      end
    end

    it "warns about unknown meta keys" do
      trace = Skylight.trace "Rack", "app.rack.request"

      expect(trace).to receive(:warn).with("Unknown meta keys will be ignored; keys=[:invalid]")

      span = trace.instrument("app.block", nil, nil, invalid: 1)
      trace.done(span)
    end

    context "source location" do
      it "allows source_location to be set" do
        trace = Skylight.trace "Rack", "app.rack.request"
        span = trace.instrument("app.block", nil, nil, source_location: "foo/bar.rb:1")
        trace.done(span)
        trace.submit

        server.wait resource: "/report"

        annotation = get_annotation_val(spans[1], :SourceLocation)
        expect(annotation&.string_val).to eq("foo/bar.rb:1")
      end

      it "allows only source_file to be set" do
        trace = Skylight.trace "Rack", "app.rack.request"
        span = trace.instrument("app.block", nil, nil, source_file: "foo/bar.rb")
        trace.done(span)
        trace.submit

        server.wait resource: "/report"

        annotation = get_annotation_val(spans[1], :SourceLocation)
        expect(annotation&.string_val).to eq("foo/bar.rb")
      end

      it "allows only source_file and source_line to be set" do
        trace = Skylight.trace "Rack", "app.rack.request"
        span = trace.instrument("app.block", nil, nil, source_file: "foo/bar.rb", source_line: 123)
        trace.done(span)
        trace.submit

        server.wait resource: "/report"

        annotation = get_annotation_val(spans[1], :SourceLocation)
        expect(annotation&.string_val).to eq("foo/bar.rb:123")
      end

      it "ignores source_line without source_file" do
        trace = Skylight.trace "Rack", "app.rack.request"

        expect(trace).to receive(:warn).with("Ignoring source_line without source_file; source_line=123")

        span = trace.instrument("app.block", nil, nil, source_line: 123)
        trace.done(span)
        trace.submit

        server.wait resource: "/report"

        annotation = get_annotation_val(spans[1], :SourceLocation)
        expect(annotation).to be_nil
      end

      it "gives priority to source_location" do
        trace = Skylight.trace "Rack", "app.rack.request"

        expect(trace).to receive(:warn).with(
          "Found both source_location and source_file or source_line, using source_location\n" \
          "  location=foo/bar.rb:1; file=foo.rb; line=123")

        span = trace.instrument("app.block", nil, nil,
                                source_location: "foo/bar.rb:1", source_file: "foo.rb", source_line: 123)
        trace.done(span)
        trace.submit

        server.wait resource: "/report"

        annotation = get_annotation_val(spans[1], :SourceLocation)
        expect(annotation&.string_val).to eq("foo/bar.rb:1")
      end
    end

    def spans
      server.reports[0].endpoints[0].traces[0].spans
    end

    def get_annotation_val(span, key)
      key = SpecHelper::Messages::Annotation::AnnotationKey.const_get(key)
      annotation = span.annotations.find { |a| a.key == key }
      annotation&.val
    end
  end
end
