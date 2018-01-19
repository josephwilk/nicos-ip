require 'logger'
require 'abstract_unit'
require 'active_support/cache'
require 'dependencies_test_helpers'

module ActiveSupport
  module Cache
    module Strategy
      module LocalCache
        class MiddlewareTest < ActiveSupport::TestCase
          def test_local_cache_cleared_on_close
            key = "super awesome key"
            assert_nil LocalCacheRegistry.cache_for key
            middleware = Middleware.new('<3', key).new(->(env) {
              assert LocalCacheRegistry.cache_for(key), 'should have a cache'
              [200, {}, []]
            })
            _, _, body = middleware.call({})
            assert LocalCacheRegistry.cache_for(key), 'should still have a cache'
            body.each { }
            assert LocalCacheRegistry.cache_for(key), 'should still have a cache'
            body.close
            assert_nil LocalCacheRegistry.cache_for(key)
          end

          def test_local_cache_cleared_on_exception
            key = "super awesome key"
            assert_nil LocalCacheRegistry.cache_for key
            middleware = Middleware.new('<3', key).new(->(env) {
              assert LocalCacheRegistry.cache_for(key), 'should have a cache'
              raise
            })
            assert_raises(RuntimeError) { middleware.call({}) }
            assert_nil LocalCacheRegistry.cache_for(key)
          end
        end
      end
    end
  end
end

class CacheKeyTest < ActiveSupport::TestCase
  def test_entry_legacy_optional_ivars
    legacy = Class.new(ActiveSupport::Cache::Entry) do
      def initialize(value, options = {})
        @value = value
        @expires_in = nil
        @created_at = nil
        super
      end
    end

    entry = legacy.new 'foo'
    assert_equal 'foo', entry.value
  end

  def test_expand_cache_key
    assert_equal '1/2/true', ActiveSupport::Cache.expand_cache_key([1, '2', true])
    assert_equal 'name/1/2/true', ActiveSupport::Cache.expand_cache_key([1, '2', true], :name)
  end

  def test_expand_cache_key_with_rails_cache_id
    begin
      ENV['RAILS_CACHE_ID'] = 'c99'
      assert_equal 'c99/foo', ActiveSupport::Cache.expand_cache_key(:foo)
      assert_equal 'c99/foo', ActiveSupport::Cache.expand_cache_key([:foo])
      assert_equal 'c99/foo/bar', ActiveSupport::Cache.expand_cache_key([:foo, :bar])
      assert_equal 'nm/c99/foo', ActiveSupport::Cache.expand_cache_key(:foo, :nm)
      assert_equal 'nm/c99/foo', ActiveSupport::Cache.expand_cache_key([:foo], :nm)
      assert_equal 'nm/c99/foo/bar', ActiveSupport::Cache.expand_cache_key([:foo, :bar], :nm)
    ensure
      ENV['RAILS_CACHE_ID'] = nil
    end
  end

  def test_expand_cache_key_with_rails_app_version
    begin
      ENV['RAILS_APP_VERSION'] = 'rails3'
      assert_equal 'rails3/foo', ActiveSupport::Cache.expand_cache_key(:foo)
    ensure
      ENV['RAILS_APP_VERSION'] = nil
    end
  end

  def test_expand_cache_key_rails_cache_id_should_win_over_rails_app_version
    begin
      ENV['RAILS_CACHE_ID'] = 'c99'
      ENV['RAILS_APP_VERSION'] = 'rails3'
      assert_equal 'c99/foo', ActiveSupport::Cache.expand_cache_key(:foo)
    ensure
      ENV['RAILS_CACHE_ID'] = nil
      ENV['RAILS_APP_VERSION'] = nil
    end
  end

  def test_expand_cache_key_respond_to_cache_key
    key = 'foo'
    def key.cache_key
      :foo_key
    end
    assert_equal 'foo_key', ActiveSupport::Cache.expand_cache_key(key)
  end

  def test_expand_cache_key_array_with_something_that_responds_to_cache_key
    key = 'foo'
    def key.cache_key
      :foo_key
    end
    assert_equal 'foo_key', ActiveSupport::Cache.expand_cache_key([key])
  end

  def test_expand_cache_key_of_nil
    assert_equal '', ActiveSupport::Cache.expand_cache_key(nil)
  end

  def test_expand_cache_key_of_false
    assert_equal 'false', ActiveSupport::Cache.expand_cache_key(false)
  end

  def test_expand_cache_key_of_true
    assert_equal 'true', ActiveSupport::Cache.expand_cache_key(true)
  end

  def test_expand_cache_key_of_array_like_object
    assert_equal 'foo/bar/baz', ActiveSupport::Cache.expand_cache_key(%w{foo bar baz}.to_enum)
  end
end

class CacheStoreSettingTest < ActiveSupport::TestCase
  def test_file_fragment_cache_store
    store = ActiveSupport::Cache.lookup_store :file_store, "/path/to/cache/directory"
    assert_kind_of(ActiveSupport::Cache::FileStore, store)
    assert_equal "/path/to/cache/directory", store.cache_path
  end

  def test_mem_cache_fragment_cache_store
    Dalli::Client.expects(:new).with(%w[localhost], {})
    store = ActiveSupport::Cache.lookup_store :mem_cache_store, "localhost"
    assert_kind_of(ActiveSupport::Cache::MemCacheStore, store)
  end

  def test_mem_cache_fragment_cache_store_with_given_mem_cache
    mem_cache = Dalli::Client.new
    Dalli::Client.expects(:new).never
    store = ActiveSupport::Cache.lookup_store :mem_cache_store, mem_cache
    assert_kind_of(ActiveSupport::Cache::MemCacheStore, store)
  end

  def test_mem_cache_fragment_cache_store_with_not_dalli_client
    Dalli::Client.expects(:new).never
    memcache = Object.new
    assert_raises(ArgumentError) do
      ActiveSupport::Cache.lookup_store :mem_cache_store, memcache
    end
  end

  def test_mem_cache_fragment_cache_store_with_multiple_servers
    Dalli::Client.expects(:new).with(%w[localhost 192.168.1.1], {})
    store = ActiveSupport::Cache.lookup_store :mem_cache_store, "localhost", '192.168.1.1'
    assert_kind_of(ActiveSupport::Cache::MemCacheStore, store)
  end

  def test_mem_cache_fragment_cache_store_with_options
    Dalli::Client.expects(:new).with(%w[localhost 192.168.1.1], { :timeout => 10 })
    store = ActiveSupport::Cache.lookup_store :mem_cache_store, "localhost", '192.168.1.1', :namespace => 'foo', :timeout => 10
    assert_kind_of(ActiveSupport::Cache::MemCacheStore, store)
    assert_equal 'foo', store.options[:namespace]
  end

  def test_object_assigned_fragment_cache_store
    store = ActiveSupport::Cache.lookup_store ActiveSupport::Cache::FileStore.new("/path/to/cache/directory")
    assert_kind_of(ActiveSupport::Cache::FileStore, store)
    assert_equal "/path/to/cache/directory", store.cache_path
  end
end

class CacheStoreNamespaceTest < ActiveSupport::TestCase
  def test_static_namespace
    cache = ActiveSupport::Cache.lookup_store(:memory_store, :namespace => "tester")
    cache.write("foo", "bar")
    assert_equal "bar", cache.read("foo")
    assert_equal "bar", cache.instance_variable_get(:@data)["tester:foo"].value
  end

  def test_proc_namespace
    test_val = "tester"
    proc = lambda{test_val}
    cache = ActiveSupport::Cache.lookup_store(:memory_store, :namespace => proc)
    cache.write("foo", "bar")
    assert_equal "bar", cache.read("foo")
    assert_equal "bar", cache.instance_variable_get(:@data)["tester:foo"].value
  end

  def test_delete_matched_key_start
    cache = ActiveSupport::Cache.lookup_store(:memory_store, :namespace => "tester")
    cache.write("foo", "bar")
    cache.write("fu", "baz")
    cache.delete_matched(/^fo/)
    assert !cache.exist?("foo")
    assert cache.exist?("fu")
  end

  def test_delete_matched_key
    cache = ActiveSupport::Cache.lookup_store(:memory_store, :namespace => "foo")
    cache.write("foo", "bar")
    cache.write("fu", "baz")
    cache.delete_matched(/OO/i)
    assert !cache.exist?("foo")
    assert cache.exist?("fu")
  end
end

# Tests the base functionality that should be identical across all cache stores.
module CacheStoreBehavior
  def test_should_read_and_write_strings
    assert @cache.write('foo', 'bar')
    assert_equal 'bar', @cache.read('foo')
  end

  def test_should_overwrite
    @cache.write('foo', 'bar')
    @cache.write('foo', 'baz')
    assert_equal 'baz', @cache.read('foo')
  end

  def test_fetch_without_cache_miss
    @cache.write('foo', 'bar')
    @cache.expects(:write).never
    assert_equal 'bar', @cache.fetch('foo') { 'baz' }
  end

  def test_fetch_with_cache_miss
    @cache.expects(:write).with('foo', 'baz', @cache.options)
    assert_equal 'baz', @cache.fetch('foo') { 'baz' }
  end

  def test_fetch_with_cache_miss_passes_key_to_block
    cache_miss = false
    assert_equal 3, @cache.fetch('foo') { |key| cache_miss = true; key.length }
    assert cache_miss

    cache_miss = false
    assert_equal 3, @cache.fetch('foo') { |key| cache_miss = true; key.length }
    assert !cache_miss
  end

  def test_fetch_with_forced_cache_miss
    @cache.write('foo', 'bar')
    @cache.expects(:read).never
    @cache.expects(:write).with('foo', 'bar', @cache.options.merge(:force => true))
    @cache.fetch('foo', :force => true) { 'bar' }
  end

  def test_fetch_with_cached_nil
    @cache.write('foo', nil)
    @cache.expects(:write).never
    assert_nil @cache.fetch('foo') { 'baz' }
  end

  def test_should_read_and_write_hash
    assert @cache.write('foo', {:a => "b"})
    assert_equal({:a => "b"}, @cache.read('foo'))
  end

  def test_should_read_and_write_integer
    assert @cache.write('foo', 1)
    assert_equal 1, @cache.read('foo')
  end

  def test_should_read_and_write_nil
    assert @cache.write('foo', nil)
    assert_equal nil, @cache.read('foo')
  end

  def test_should_read_and_write_false
    assert @cache.write('foo', false)
    assert_equal false, @cache.read('foo')
  end

  def test_read_multi
    @cache.write('foo', 'bar')
    @cache.write('fu', 'baz')
    @cache.write('fud', 'biz')
    assert_equal({"foo" => "bar", "fu" => "baz"}, @cache.read_multi('foo', 'fu'))
  end

  def test_read_multi_with_expires
    time = Time.now
    @cache.write('foo', 'bar', :expires_in => 10)
    @cache.write('fu', 'baz')
    @cache.write('fud', 'biz')
    Time.stubs(:now).returns(time + 11)
    assert_equal({"fu" => "baz"}, @cache.read_multi('foo', 'fu'))
  end

  def test_fetch_multi
    @cache.write('foo', 'bar')
    @cache.write('fud', 'biz')

    values = @cache.fetch_multi('foo', 'fu', 'fud') { |value| value * 2 }

    assert_equal({ 'foo' => 'bar', 'fu' => 'fufu', 'fud' => 'biz' }, values)
    assert_equal('fufu', @cache.read('fu'))
  end

  def test_multi_with_objects
    foo = stub(:title => 'FOO!', :cache_key => 'foo')
    bar = stub(:cache_key => 'bar')

    @cache.write('bar', 'BAM!')

    values = @cache.fetch_multi(foo, bar) { |object| object.title }

    assert_equal({ foo => 'FOO!', bar => 'BAM!' }, values)
  end

  def test_read_and_write_compressed_small_data
    @cache.write('foo', 'bar', :compress => true)
    assert_equal 'bar', @cache.read('foo')
  end

  def test_read_and_write_compressed_large_data
    @cache.write('foo', 'bar', :compress => true, :compress_threshold => 2)
    assert_equal 'bar', @cache.read('foo')
  end

  def test_read_and_write_compressed_nil
    @cache.write('foo', nil, :compress => true)
    assert_nil @cache.read('foo')
  end

  def test_cache_key
    obj = Object.new
    def obj.cache_key
      :foo
    end
    @cache.write(obj, "bar")
    assert_equal "bar", @cache.read("foo")
  end

  def test_param_as_cache_key
    obj = Object.new
    def obj.to_param
      "foo"
    end
    @cache.write(obj, "bar")
    assert_equal "bar", @cache.read("foo")
  end

  def test_array_as_cache_key
    @cache.write([:fu, "foo"], "bar")
    assert_equal "bar", @cache.read("fu/foo")
  end

  def test_hash_as_cache_key
    @cache.write({:foo => 1, :fu => 2}, "bar")
    assert_equal "bar", @cache.read("foo=1/fu=2")
  end

  def test_keys_are_case_sensitive
    @cache.write("foo", "bar")
    assert_nil @cache.read("FOO")
  end

  def test_exist
    @cache.write('foo', 'bar')
    assert_equal true, @cache.exist?('foo')
    assert_equal false, @cache.exist?('bar')
  end

  def test_nil_exist
    @cache.write('foo', nil)
    assert @cache.exist?('foo')
  end

  def test_delete
    @cache.write('foo', 'bar')
    assert @cache.exist?('foo')
    assert @cache.delete('foo')
    assert !@cache.exist?('foo')
  end

  def test_original_store_objects_should_not_be_immutable
    bar = 'bar'
    @cache.write('foo', bar)
    assert_nothing_raised { bar.gsub!(/.*/, 'baz') }
  end

  def test_expires_in
    time = Time.local(2008, 4, 24)
    Time.stubs(:now).returns(time)

    @cache.write('foo', 'bar')
    assert_equal 'bar', @cache.read('foo')

    Time.stubs(:now).returns(time + 30)
    assert_equal 'bar', @cache.read('foo')

    Time.stubs(:now).returns(time + 61)
    assert_nil @cache.read('foo')
  end

  def test_race_condition_protection
    time = Time.now
    @cache.write('foo', 'bar', :expires_in => 60)
    Time.stubs(:now).returns(time + 61)
    result = @cache.fetch('foo', :race_condition_ttl => 10) do
      assert_equal 'bar', @cache.read('foo')
      "baz"
    end
    assert_equal "baz", result
  end

  def test_race_condition_protection_is_limited
    time = Time.now
    @cache.write('foo', 'bar', :expires_in => 60)
    Time.stubs(:now).returns(time + 71)
    result = @cache.fetch('foo', :race_condition_ttl => 10) do
      assert_equal nil, @cache.read('foo')
      "baz"
    end
    assert_equal "baz", result
  end

  def test_race_condition_protection_is_safe
    time = Time.now
    @cache.write('foo', 'bar', :expires_in => 60)
    Time.stubs(:now).returns(time + 61)
    begin
      @cache.fetch('foo', :race_condition_ttl => 10) do
        assert_equal 'bar', @cache.read('foo')
        raise ArgumentError.new
      end
    rescue ArgumentError
    end
    assert_equal "bar", @cache.read('foo')
    Time.stubs(:now).returns(time + 91)
    assert_nil @cache.read('foo')
  end

  def test_crazy_key_characters
    crazy_key = "#/:*(<+=> )&$%@?;'\"\'`~-"
    assert @cache.write(crazy_key, "1", :raw => true)
    assert_equal "1", @cache.read(crazy_key)
    assert_equal "1", @cache.fetch(crazy_key)
    assert @cache.delete(crazy_key)
    assert_equal "2", @cache.fetch(crazy_key, :raw => true) { "2" }
    assert_equal 3, @cache.increment(crazy_key)
    assert_equal 2, @cache.decrement(crazy_key)
  end

  def test_really_long_keys
    key = ""
    900.times{key << "x"}
    assert @cache.write(key, "bar")
    assert_equal "bar", @cache.read(key)
    assert_equal "bar", @cache.fetch(key)
    assert_nil @cache.read("#{key}x")
    assert_equal({key => "bar"}, @cache.read_multi(key))
    assert @cache.delete(key)
  end
end

# https://rails.lighthouseapp.com/projects/8994/tickets/6225-memcachestore-cant-deal-with-umlauts-and-special-characters
# The error is caused by character encodings that can't be compared with ASCII-8BIT regular expressions and by special
# characters like the umlaut in UTF-8.
module EncodedKeyCacheBehavior
  Encoding.list.each do |encoding|
    define_method "test_#{encoding.name.underscore}_encoded_values" do
      key = "foo".force_encoding(encoding)
      assert @cache.write(key, "1", :raw => true)
      assert_equal "1", @cache.read(key)
      assert_equal "1", @cache.fetch(key)
      assert @cache.delete(key)
      assert_equal "2", @cache.fetch(key, :raw => true) { "2" }
      assert_equal 3, @cache.increment(key)
      assert_equal 2, @cache.decrement(key)
    end
  end

  def test_common_utf8_values
    key = "\xC3\xBCmlaut".force_encoding(Encoding::UTF_8)
    assert @cache.write(key, "1", :raw => true)
    assert_equal "1", @cache.read(key)
    assert_equal "1", @cache.fetch(key)
    assert @cache.delete(key)
    assert_equal "2", @cache.fetch(key, :raw => true) { "2" }
    assert_equal 3, @cache.increment(key)
    assert_equal 2, @cache.decrement(key)
  end

  def test_retains_encoding
    key = "\xC3\xBCmlaut".force_encoding(Encoding::UTF_8)
    assert @cache.write(key, "1", :raw => true)
    assert_equal Encoding::UTF_8, key.encoding
  end
end

module CacheDeleteMatchedBehavior
  def test_delete_matched
    @cache.write("foo", "bar")
    @cache.write("fu", "baz")
    @cache.write("foo/bar", "baz")
    @cache.write("fu/baz", "bar")
    @cache.delete_matched(/oo/)
    assert !@cache.exist?("foo")
    assert @cache.exist?("fu")
    assert !@cache.exist?("foo/bar")
    assert @cache.exist?("fu/baz")
  end
end

module CacheIncrementDecrementBehavior
  def test_increment
    @cache.write('foo', 1, :raw => true)
    assert_equal 1, @cache.read('foo').to_i
    assert_equal 2, @cache.increment('foo')
    assert_equal 2, @cache.read('foo').to_i
    assert_equal 3, @cache.increment('foo')
    assert_equal 3, @cache.read('foo').to_i
    assert_nil @cache.increment('bar')
  end

  def test_decrement
    @cache.write('foo', 3, :raw => true)
    assert_equal 3, @cache.read('foo').to_i
    assert_equal 2, @cache.decrement('foo')
    assert_equal 2, @cache.read('foo').to_i
    assert_equal 1, @cache.decrement('foo')
    assert_equal 1, @cache.read('foo').to_i
    assert_nil @cache.decrement('bar')
  end
end

module LocalCacheBehavior
  def test_local_writes_are_persistent_on_the_remote_cache
    retval = @cache.with_local_cache do
      @cache.write('foo', 'bar')
    end
    assert retval
    assert_equal 'bar', @cache.read('foo')
  end

  def test_clear_also_clears_local_cache
    @cache.with_local_cache do
      @cache.write('foo', 'bar')
      @cache.clear
      assert_nil @cache.read('foo')
    end

    assert_nil @cache.read('foo')
  end

  def test_local_cache_of_write
    @cache.with_local_cache do
      @cache.write('foo', 'bar')
      @peek.delete('foo')
      assert_equal 'bar', @cache.read('foo')
    end
  end

  def test_local_cache_of_read
    @cache.write('foo', 'bar')
    @cache.with_local_cache do
      assert_equal 'bar', @cache.read('foo')
    end
  end

  def test_local_cache_of_write_nil
    @cache.with_local_cache do
      assert @cache.write('foo', nil)
      assert_nil @cache.read('foo')
      @peek.write('foo', 'bar')
      assert_nil @cache.read('foo')
    end
  end

  def test_local_cache_of_delete
    @cache.with_local_cache do
      @cache.write('foo', 'bar')
      @cache.delete('foo')
      assert_nil @cache.read('foo')
    end
  end

  def test_local_cache_of_exist
    @cache.with_local_cache do
      @cache.write('foo', 'bar')
      @peek.delete('foo')
      assert @cache.exist?('foo')
    end
  end

  def test_local_cache_of_increment
    @cache.with_local_cache do
      @cache.write('foo', 1, :raw => true)
      @peek.write('foo', 2, :raw => true)
      @cache.increment('foo')
      assert_equal 3, @cache.read('foo')
    end
  end

  def test_local_cache_of_decrement
    @cache.with_local_cache do
      @cache.write('foo', 1, :raw => true)
      @peek.write('foo', 3, :raw => true)
      @cache.decrement('foo')
      assert_equal 2, @cache.read('foo')
    end
  end

  def test_middleware
    app = lambda { |env|
      result = @cache.write('foo', 'bar')
      assert_equal 'bar', @cache.read('foo') # make sure 'foo' was written
      assert result
      [200, {}, []]
    }
    app = @cache.middleware.new(app)
    app.call({})
  end
end

module AutoloadingCacheBehavior
  include DependenciesTestHelpers
  def test_simple_autoloading
    with_autoloading_fixtures do
      @cache.write('foo', E.new)
    end

    remove_constants(:E)
    ActiveSupport::Dependencies.clear

    with_autoloading_fixtures do
      assert_kind_of E, @cache.read('foo')
    end

    remove_constants(:E)
    ActiveSupport::Dependencies.clear
  end

  def test_two_classes_autoloading
    with_autoloading_fixtures do
      @cache.write('foo', [E.new, ClassFolder.new])
    end

    remove_constants(:E, :ClassFolder)
    ActiveSupport::Dependencies.clear

    with_autoloading_fixtures do
      loaded = @cache.read('foo')
      assert_kind_of Array, loaded
      assert_equal 2, loaded.size
      assert_kind_of E, loaded[0]
      assert_kind_of ClassFolder, loaded[1]
    end

    remove_constants(:E, :ClassFolder)
    ActiveSupport::Dependencies.clear
  end
end

class FileStoreTest < ActiveSupport::TestCase
  def setup
    Dir.mkdir(cache_dir) unless File.exist?(cache_dir)
    @cache = ActiveSupport::Cache.lookup_store(:file_store, cache_dir, :expires_in => 60)
    @peek = ActiveSupport::Cache.lookup_store(:file_store, cache_dir, :expires_in => 60)
    @cache_with_pathname = ActiveSupport::Cache.lookup_store(:file_store, Pathname.new(cache_dir), :expires_in => 60)

    @buffer = StringIO.new
    @cache.logger = ActiveSupport::Logger.new(@buffer)
  end

  def teardown
    FileUtils.rm_r(cache_dir)
  end

  def cache_dir
    File.join(Dir.pwd, 'tmp_cache')
  end

  include CacheStoreBehavior
  include LocalCacheBehavior
  include CacheDeleteMatchedBehavior
  include CacheIncrementDecrementBehavior
  include AutoloadingCacheBehavior

  def test_clear
    filepath = File.join(cache_dir, ".gitkeep")
    FileUtils.touch(filepath)
    @cache.clear
    assert File.exist?(filepath)
  end

  def test_key_transformation
    key = @cache.send(:key_file_path, "views/index?id=1")
    assert_equal "views/index?id=1", @cache.send(:file_path_key, key)
  end

  def test_key_transformation_with_pathname
    FileUtils.touch(File.join(cache_dir, "foo"))
    key = @cache_with_pathname.send(:key_file_path, "views/index?id=1")
    assert_equal "views/index?id=1", @cache_with_pathname.send(:file_path_key, key)
  end

  # Test that generated cache keys are short enough to have Tempfile stuff added to them and
  # remain valid
  def test_filename_max_size
    key = "#{'A' * ActiveSupport::Cache::FileStore::FILENAME_MAX_SIZE}"
    path = @cache.send(:key_file_path, key)
    Dir::Tmpname.create(path) do |tmpname, n, opts|
      assert File.basename(tmpname+'.lock').length <= 255, "Temp filename too long: #{File.basename(tmpname+'.lock').length}"
    end
  end

  # Because file systems have a maximum filename size, filenames > max size should be split in to directories
  # If filename is 'AAAAB', where max size is 4, the returned path should be AAAA/B
  def test_key_transformation_max_filename_size
    key = "#{'A' * ActiveSupport::Cache::FileStore::FILENAME_MAX_SIZE}B"
    path = @cache.send(:key_file_path, key)
    assert path.split('/').all? { |dir_name| dir_name.size <= ActiveSupport::Cache::FileStore::FILENAME_MAX_SIZE}
    assert_equal 'B', File.basename(path)
  end

  # If nothing has been stored in the cache, there is a chance the cache directory does not yet exist
  # Ensure delete_matched gracefully handles this case
  def test_delete_matched_when_cache_directory_does_not_exist
    assert_nothing_raised(Exception) do
      ActiveSupport::Cache::FileStore.new('/test/cache/directory').delete_matched(/does_not_exist/)
    end
  end

  def test_delete_does_not_delete_empty_parent_dir
    sub_cache_dir = File.join(cache_dir, 'subdir/')
    sub_cache_store = ActiveSupport::Cache::FileStore.new(sub_cache_dir)
    assert_nothing_raised(Exception) do
      assert sub_cache_store.write('foo', 'bar')
      assert sub_cache_store.delete('foo')
    end
    assert File.exist?(cache_dir), "Parent of top level cache dir was deleted!"
    assert File.exist?(sub_cache_dir), "Top level cache dir was deleted!"
    assert Dir.entries(sub_cache_dir).reject {|f| ActiveSupport::Cache::FileStore::EXCLUDED_DIRS.include?(f)}.empty?
  end

  def test_log_exception_when_cache_read_fails
    File.expects(:exist?).raises(StandardError, "failed")
    @cache.send(:read_entry, "winston", {})
    assert @buffer.string.present?
  end

  def test_cleanup_removes_all_expired_entries
    time = Time.now
    @cache.write('foo', 'bar', expires_in: 10)
    @cache.write('baz', 'qux')
    @cache.write('quux', 'corge', expires_in: 20)
    Time.stubs(:now).returns(time + 15)
    @cache.cleanup
    assert_not @cache.exist?('foo')
    assert @cache.exist?('baz')
    assert @cache.exist?('quux')
  end

  def test_write_with_unless_exist
    assert_equal true, @cache.write(1, "aaaaaaaaaa")
    assert_equal false, @cache.write(1, "aaaaaaaaaa", unless_exist: true)
    @cache.write(1, nil)
    assert_equal false, @cache.write(1, "aaaaaaaaaa", unless_exist: true)
  end
end

class MemoryStoreTest < ActiveSupport::TestCase
  def setup
    @record_size = ActiveSupport::Cache.lookup_store(:memory_store).send(:cached_size, 1, ActiveSupport::Cache::Entry.new("aaaaaaaaaa"))
    @cache = ActiveSupport::Cache.lookup_store(:memory_store, :expires_in => 60, :size => @record_size * 10 + 1)
  end

  include CacheStoreBehavior
  include CacheDeleteMatchedBehavior
  include CacheIncrementDecrementBehavior

  def test_prune_size
    @cache.write(1, "aaaaaaaaaa") && sleep(0.001)
    @cache.write(2, "bbbbbbbbbb") && sleep(0.001)
    @cache.write(3, "cccccccccc") && sleep(0.001)
    @cache.write(4, "dddddddddd") && sleep(0.001)
    @cache.write(5, "eeeeeeeeee") && sleep(0.001)
    @cache.read(2) && sleep(0.001)
    @cache.read(4)
    @cache.prune(@record_size * 3)
    assert @cache.exist?(5)
    assert @cache.exist?(4)
    assert !@cache.exist?(3), "no entry"
    assert @cache.exist?(2)
    assert !@cache.exist?(1), "no entry"
  end

  def test_prune_size_on_write
    @cache.write(1, "aaaaaaaaaa") && sleep(0.001)
    @cache.write(2, "bbbbbbbbbb") && sleep(0.001)
    @cache.write(3, "cccccccccc") && sleep(0.001)
    @cache.write(4, "dddddddddd") && sleep(0.001)
    @cache.write(5, "eeeeeeeeee") && sleep(0.001)
    @cache.write(6, "ffffffffff") && sleep(0.001)
    @cache.write(7, "gggggggggg") && sleep(0.001)
    @cache.write(8, "hhhhhhhhhh") && sleep(0.001)
    @cache.write(9, "iiiiiiiiii") && sleep(0.001)
    @cache.write(10, "kkkkkkkkkk") && sleep(0.001)
    @cache.read(2) && sleep(0.001)
    @cache.read(4) && sleep(0.001)
    @cache.write(11, "llllllllll")
    assert @cache.exist?(11)
    assert @cache.exist?(10)
    assert @cache.exist?(9)
    assert @cache.exist?(8)
    assert @cache.exist?(7)
    assert !@cache.exist?(6), "no entry"
    assert !@cache.exist?(5), "no entry"
    assert @cache.exist?(4)
    assert !@cache.exist?(3), "no entry"
    assert @cache.exist?(2)
    assert !@cache.exist?(1), "no entry"
  end

  def test_prune_size_on_write_based_on_key_length
    @cache.write(1, "aaaaaaaaaa") && sleep(0.001)
    @cache.write(2, "bbbbbbbbbb") && sleep(0.001)
    @cache.write(3, "cccccccccc") && sleep(0.001)
    @cache.write(4, "dddddddddd") && sleep(0.001)
    @cache.write(5, "eeeeeeeeee") && sleep(0.001)
    @cache.write(6, "ffffffffff") && sleep(0.001)
    @cache.write(7, "gggggggggg") && sleep(0.001)
    @cache.write(8, "hhhhhhhhhh") && sleep(0.001)
    @cache.write(9, "iiiiiiiiii") && sleep(0.001)
    long_key = '*' * 2 * @record_size
    @cache.write(long_key, "llllllllll")
    assert @cache.exist?(long_key)
    assert @cache.exist?(9)
    assert @cache.exist?(8)
    assert @cache.exist?(7)
    assert @cache.exist?(6)
    assert !@cache.exist?(5), "no entry"
    assert !@cache.exist?(4), "no entry"
    assert !@cache.exist?(3), "no entry"
    assert !@cache.exist?(2), "no entry"
    assert !@cache.exist?(1), "no entry"
  end

  def test_pruning_is_capped_at_a_max_time
    def @cache.delete_entry (*args)
      sleep(0.01)
      super
    end
    @cache.write(1, "aaaaaaaaaa") && sleep(0.001)
    @cache.write(2, "bbbbbbbbbb") && sleep(0.001)
    @cache.write(3, "cccccccccc") && sleep(0.001)
    @cache.write(4, "dddddddddd") && sleep(0.001)
    @cache.write(5, "eeeeeeeeee") && sleep(0.001)
    @cache.prune(30, 0.001)
    assert @cache.exist?(5)
    assert @cache.exist?(4)
    assert @cache.exist?(3)
    assert @cache.exist?(2)
    assert !@cache.exist?(1)
  end

  def test_write_with_unless_exist
    assert_equal true, @cache.write(1, "aaaaaaaaaa")
    assert_equal false, @cache.write(1, "aaaaaaaaaa", :unless_exist => true)
    @cache.write(1, nil)
    assert_equal false, @cache.write(1, "aaaaaaaaaa", :unless_exist => true)
  end
end

class MemCacheStoreTest < ActiveSupport::TestCase
  require 'dalli'

  begin
    ss = Dalli::Client.new('localhost:11211').stats
    raise Dalli::DalliError unless ss['localhost:11211']

    MEMCACHE_UP = true
  rescue Dalli::DalliError
    $stderr.puts "Skipping memcached tests. Start memcached and try again."
    MEMCACHE_UP = false
  end

  def setup
    skip "memcache server is not up" unless MEMCACHE_UP

    @cache = ActiveSupport::Cache.lookup_store(:mem_cache_store, :expires_in => 60)
    @peek = ActiveSupport::Cache.lookup_store(:mem_cache_store)
    @data = @cache.instance_variable_get(:@data)
    @cache.clear
    @cache.silence!
    @cache.logger = ActiveSupport::Logger.new("/dev/null")
  end

  include CacheStoreBehavior
  include LocalCacheBehavior
  include CacheIncrementDecrementBehavior
  include EncodedKeyCacheBehavior
  include AutoloadingCacheBehavior

  def test_raw_values
    cache = ActiveSupport::Cache.lookup_store(:mem_cache_store, :raw => true)
    cache.clear
    cache.write("foo", 2)
    assert_equal "2", cache.read("foo")
  end

  def test_raw_values_with_marshal
    cache = ActiveSupport::Cache.lookup_store(:mem_cache_store, :raw => true)
    cache.clear
    cache.write("foo", Marshal.dump([]))
    assert_equal [], cache.read("foo")
  end

  def test_local_cache_raw_values
    cache = ActiveSupport::Cache.lookup_store(:mem_cache_store, :raw => true)
    cache.clear
    cache.with_local_cache do
      cache.write("foo", 2)
      assert_equal "2", cache.read("foo")
    end
  end

  def test_local_cache_raw_values_with_marshal
    cache = ActiveSupport::Cache.lookup_store(:mem_cache_store, :raw => true)
    cache.clear
    cache.with_local_cache do
      cache.write("foo", Marshal.dump([]))
      assert_equal [], cache.read("foo")
    end
  end

  def test_read_should_return_a_different_object_id_each_time_it_is_called
    @cache.write('foo', 'bar')
    assert_not_equal @cache.read('foo').object_id, @cache.read('foo').object_id
    value = @cache.read('foo')
    value << 'bingo'
    assert_not_equal value, @cache.read('foo')
  end
end

class NullStoreTest < ActiveSupport::TestCase
  def setup
    @cache = ActiveSupport::Cache.lookup_store(:null_store)
  end

  def test_clear
    @cache.clear
  end

  def test_cleanup
    @cache.cleanup
  end

  def test_write
    assert_equal true, @cache.write("name", "value")
  end

  def test_read
    @cache.write("name", "value")
    assert_nil @cache.read("name")
  end

  def test_delete
    @cache.write("name", "value")
    assert_equal false, @cache.delete("name")
  end

  def test_increment
    @cache.write("name", 1, :raw => true)
    assert_nil @cache.increment("name")
  end

  def test_decrement
    @cache.write("name", 1, :raw => true)
    assert_nil @cache.increment("name")
  end

  def test_delete_matched
    @cache.write("name", "value")
    @cache.delete_matched(/name/)
  end

  def test_local_store_strategy
    @cache.with_local_cache do
      @cache.write("name", "value")
      assert_equal "value", @cache.read("name")
      @cache.delete("name")
      assert_nil @cache.read("name")
      @cache.write("name", "value")
    end
    assert_nil @cache.read("name")
  end

  def test_setting_nil_cache_store
    assert ActiveSupport::Cache.lookup_store.class.name, ActiveSupport::Cache::NullStore.name
  end
end

class CacheStoreLoggerTest < ActiveSupport::TestCase
  def setup
    @cache = ActiveSupport::Cache.lookup_store(:memory_store)

    @buffer = StringIO.new
    @cache.logger = ActiveSupport::Logger.new(@buffer)
  end

  def test_logging
    @cache.fetch('foo') { 'bar' }
    assert @buffer.string.present?
  end

  def test_mute_logging
    @cache.mute { @cache.fetch('foo') { 'bar' } }
    assert @buffer.string.blank?
  end
end

class CacheEntryTest < ActiveSupport::TestCase
  def test_expired
    entry = ActiveSupport::Cache::Entry.new("value")
    assert !entry.expired?, 'entry not expired'
    entry = ActiveSupport::Cache::Entry.new("value", :expires_in => 60)
    assert !entry.expired?, 'entry not expired'
    time = Time.now + 61
    Time.stubs(:now).returns(time)
    assert entry.expired?, 'entry is expired'
  end

  def test_compress_values
    value = "value" * 100
    entry = ActiveSupport::Cache::Entry.new(value, :compress => true, :compress_threshold => 1)
    assert_equal value, entry.value
    assert(value.bytesize > entry.size, "value is compressed")
  end

  def test_non_compress_values
    value = "value" * 100
    entry = ActiveSupport::Cache::Entry.new(value)
    assert_equal value, entry.value
    assert_equal value.bytesize, entry.size
  end

  def test_restoring_version_4beta1_entries
    version_4beta1_entry = ActiveSupport::Cache::Entry.allocate
    version_4beta1_entry.instance_variable_set(:@v, "hello")
    version_4beta1_entry.instance_variable_set(:@x, Time.now.to_i + 60)
    entry = Marshal.load(Marshal.dump(version_4beta1_entry))
    assert_equal "hello", entry.value
    assert_equal false, entry.expired?
  end

  def test_restoring_compressed_version_4beta1_entries
    version_4beta1_entry = ActiveSupport::Cache::Entry.allocate
    version_4beta1_entry.instance_variable_set(:@v, Zlib::Deflate.deflate(Marshal.dump("hello")))
    version_4beta1_entry.instance_variable_set(:@c, true)
    entry = Marshal.load(Marshal.dump(version_4beta1_entry))
    assert_equal "hello", entry.value
  end

  def test_restoring_expired_version_4beta1_entries
    version_4beta1_entry = ActiveSupport::Cache::Entry.allocate
    version_4beta1_entry.instance_variable_set(:@v, "hello")
    version_4beta1_entry.instance_variable_set(:@x, Time.now.to_i - 1)
    entry = Marshal.load(Marshal.dump(version_4beta1_entry))
    assert_equal "hello", entry.value
    assert_equal true, entry.expired?
  end
end
